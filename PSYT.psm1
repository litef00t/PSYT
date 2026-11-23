function Test-YouTubeVideoId {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$InputString
    )

    if ([string]::IsNullOrWhiteSpace($InputString) -or $InputString -match '[\s\p{Cc}]') {
        Write-Verbose 'No valid YouTube video ID found in the string.'
        return @()
    }

    if ($InputString -cmatch '^[A-Za-z0-9_-]{11}\z') {
        Write-Verbose "Valid YouTube video ID format: $InputString"
        return $InputString
    }

    $candidate = $InputString
    if ($candidate -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        if ($candidate -match '^(?:(?:www|m|music)\.)?(?:youtube\.com|youtu\.be)/') {
            $candidate = "https://$candidate"
        } else {
            Write-Verbose 'No valid YouTube video ID found in the string.'
            return @()
        }
    }

    $parsedUri = $null
    if (-not [System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$parsedUri)) {
        Write-Verbose 'No valid YouTube video ID found in the string.'
        return @()
    }

    if ($parsedUri.Scheme -notin @('http', 'https') -or -not $parsedUri.IsDefaultPort -or -not [string]::IsNullOrEmpty($parsedUri.UserInfo)) {
        Write-Verbose 'No valid YouTube video ID found in the string.'
        return @()
    }

    $hostName = $parsedUri.Host.ToLowerInvariant()
    $videoId = $null

    if ($hostName -in @('youtu.be', 'www.youtu.be')) {
        if ($parsedUri.AbsolutePath -match '^/([A-Za-z0-9_-]{11})/?\z') {
            $videoId = $Matches[1]
        }
    } elseif ($hostName -in @('youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com')) {
        if ($parsedUri.AbsolutePath -eq '/watch') {
            $query = $parsedUri.Query.TrimStart('?')
            if (-not [string]::IsNullOrEmpty($query)) {
                foreach ($pair in ($query -split '&')) {
                    if ($pair -match '^v=([^&]+)\z') {
                        $decoded = [System.Uri]::UnescapeDataString($Matches[1])
                        if ($decoded -cmatch '^[A-Za-z0-9_-]{11}\z') {
                            $videoId = $decoded
                        }
                        break
                    }
                }
            }
        } elseif ($parsedUri.AbsolutePath -match '^/(?:embed|v|shorts|live)/([A-Za-z0-9_-]{11})/?\z') {
            $videoId = $Matches[1]
        }
    }

    if ($videoId) {
        Write-Verbose "Valid YouTube video ID found: $videoId"
        return $videoId
    }

    Write-Verbose 'No valid YouTube video ID found in the string.'
    return @()
}

function Get-PSYTWebSession {
    [CmdletBinding()]
    param()

    # Reuse one WebRequestSession for the module import lifetime so YouTube consent cookies persist across requests.
    if (-not $script:PSYT_WebSession) {
        $script:PSYT_WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    }

    return $script:PSYT_WebSession
}

function Get-PSYTRequestHeader {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    # Lightweight browser-like headers (Chrome desktop UA) so YouTube returns standard watch/caption payloads.
    return @{
        'Accept-Language' = 'en-US,en;q=0.9'
        'Accept'          = 'application/xml,text/xml,text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8'
        'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }
}

function Add-PSYTConsentCookie {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,

        [Parameter(Mandatory)]
        [string]$ConsentValue
    )

    try {
        $cookie = New-Object System.Net.Cookie
        $cookie.Name = 'CONSENT'
        $cookie.Value = "YES+$ConsentValue"
        $cookie.Path = '/'
        $cookie.Domain = '.youtube.com'
        $WebSession.Cookies.Add($cookie)
    } catch {
        # Best-effort; if this fails, the subsequent request will still indicate consent is required.
        Write-Debug "Failed to add CONSENT cookie: $($_.Exception.Message)"
    }
}

function Get-PSYTInnertubeApiKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    $match = [regex]::Match($Html, '"INNERTUBE_API_KEY":\s*"([a-zA-Z0-9_-]+)"')
    if ($match.Success -and $match.Groups.Count -ge 2) {
        return $match.Groups[1].Value
    }

    return $null
}

function Get-PSYTInnertubeData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VideoId,

        [Parameter(Mandatory)]
        [string]$ApiKey,

        [Parameter(Mandatory)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $uri = "https://www.youtube.com/youtubei/v1/player?key=$ApiKey"
    # Client metadata mirrors youtube-transcript-api's ANDROID Innertube player request.
    $body = @{
        context = @{
            client = @{
                clientName    = 'ANDROID'
                clientVersion = '20.10.38'
            }
        }
        videoId = $VideoId
    } | ConvertTo-Json -Compress

    try {
        $request = @{
            Method                   = 'Post'
            Uri                      = $uri
            WebSession               = $WebSession
            Headers                  = $Headers
            ContentType              = 'application/json'
            Body                     = $body
            ConnectionTimeoutSeconds = 15
            OperationTimeoutSeconds  = 30
            ErrorAction              = 'Stop'
        }
        return Invoke-RestMethod @request
    } catch {
        throw "Failed to fetch Innertube player data: $($_.Exception.Message)"
    }
}

function Resolve-PSYTTimedtextUri {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Link
    )

    if ([string]::IsNullOrWhiteSpace($Link)) {
        throw 'Invalid transcript URL. Expected an HTTPS YouTube /api/timedtext URL.'
    }

    $resolvedUri = $null
    if ($Link.StartsWith('/')) {
        if ($Link.StartsWith('//')) {
            throw 'Invalid transcript URL. Expected an HTTPS YouTube /api/timedtext URL.'
        }
        $baseUri = [System.Uri]'https://www.youtube.com'
        if (-not [System.Uri]::TryCreate($baseUri, $Link, [ref]$resolvedUri)) {
            throw 'Invalid transcript URL. Expected an HTTPS YouTube /api/timedtext URL.'
        }
    } elseif (-not [System.Uri]::TryCreate($Link, [System.UriKind]::Absolute, [ref]$resolvedUri)) {
        throw 'Invalid transcript URL. Expected an HTTPS YouTube /api/timedtext URL.'
    }

    $hostName = $resolvedUri.Host.ToLowerInvariant()
    if ($resolvedUri.Scheme -ne 'https' -or
        -not $resolvedUri.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($resolvedUri.UserInfo) -or
        $hostName -notin @('www.youtube.com', 'youtube.com') -or
        $resolvedUri.AbsolutePath -cne '/api/timedtext') {
        throw 'Invalid transcript URL. Expected an HTTPS YouTube /api/timedtext URL.'
    }

    return $resolvedUri.AbsoluteUri
}

function Get-VideoPageHtml {
    <#
    .SYNOPSIS
    Retrieves the HTML content of a YouTube watch page.

    .DESCRIPTION
    Fetches the YouTube watch page for a validated video ID or URL, automatically retrying once if YouTube serves a cookie consent gate. Throws an error if the input is invalid or the request fails.

    .PARAMETER videoId
    A YouTube video ID (11 characters) or supported YouTube URL.

    .EXAMPLE
    Get-VideoPageHtml -videoId 'GikIJpUv6oo'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$videoId
    )

    $videoId = Test-YouTubeVideoId -InputString $videoId
    if (-not $videoId) {
        throw 'Provide a valid YouTube video ID or URL.'
    }
    try {
        $session = Get-PSYTWebSession
        $headers = Get-PSYTRequestHeader

        $request = @{
            Uri                      = "https://www.youtube.com/watch?v=$videoId"
            WebSession               = $session
            Headers                  = $headers
            ConnectionTimeoutSeconds = 15
            OperationTimeoutSeconds  = 30
            ErrorAction              = 'Stop'
        }
        $response = Invoke-WebRequest @request
        $html = $response.Content

        # If YouTube serves a consent page, set the CONSENT cookie and retry once (mirrors youtube-transcript-api behavior).
        if ($html -match 'action="https://consent\.youtube\.com/s"') {
            $consentMatch = [regex]::Match($html, 'name="v"\s+value="(.*?)"')
            if ($consentMatch.Success -and $consentMatch.Groups.Count -ge 2) {
                Add-PSYTConsentCookie -WebSession $session -ConsentValue $consentMatch.Groups[1].Value
                $response = Invoke-WebRequest @request
                $html = $response.Content
            } else {
                throw 'Could not resolve the YouTube consent page.'
            }

            if ($html -match 'action="https://consent\.youtube\.com/s"') {
                throw 'YouTube still requires consent after retrying.'
            }
        }
        if ($html -notmatch 'og:url' -or $html -notmatch '"playabilityStatus":') {
            if ($html -match 'class="g-recaptcha"|Sign in to confirm you.?re not a bot') {
                throw 'YouTube is blocking this request with a bot/recaptcha page.'
            }
            throw 'YouTube did not return the expected video page.'
        }
        return $html
    } catch {
        throw "Failed to fetch video page for ${videoId}: $($_.Exception.Message)"
    }
}

function Get-LangOptionsWithLink {
    <#
    .SYNOPSIS
    Retrieves available caption tracks and transcript URLs for a YouTube video.

    .DESCRIPTION
    Extracts the Innertube API key from the video watch page, queries YouTube's Innertube player API, validates playability, and returns caption track objects ordered with manual English first, followed by auto-generated English and other languages.

    .PARAMETER videoId
    A YouTube video ID (11 characters) or supported YouTube URL.

    .EXAMPLE
    Get-LangOptionsWithLink -videoId 'https://youtu.be/GikIJpUv6oo'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$videoId
    )

    $videoId = Test-YouTubeVideoId -InputString $videoId
    if (-not $videoId) {
        throw 'Provide a valid YouTube video ID or URL.'
    }
    $videoPageHtml = Get-VideoPageHtml -videoId $videoId
    if (-not $videoPageHtml) {
        throw 'YouTube returned an empty video page.'
    }

    # Match youtube-transcript-api: extract INNERTUBE_API_KEY from HTML then call Innertube player API
    # to get fresh caption tracks (avoids links which may require PO tokens / return empty bodies).
    $session = Get-PSYTWebSession
    $headers = Get-PSYTRequestHeader

    $apiKey = Get-PSYTInnertubeApiKey -Html $videoPageHtml
    if (-not $apiKey) {
        throw 'The video page does not contain an Innertube API key.'
    }

    try {
        $innertubeData = Get-PSYTInnertubeData -VideoId $videoId -ApiKey $apiKey -WebSession $session -Headers $headers
        $status = $innertubeData.playabilityStatus.status
        if (-not $status) {
            throw 'The player response is missing playability status.'
        }
        if ($status -ne 'OK') {
            throw "Video is unavailable ($status): $($innertubeData.playabilityStatus.reason)"
        }
        $captions = $innertubeData.captions.playerCaptionsTracklistRenderer
        if (-not $captions -or -not $captions.captionTracks) {
            Write-Verbose 'No captions available.'
            return @()
        }

        $rankedTracks = foreach ($track in $captions.captionTracks) {
            $name = if ($track.name.runs) {
                ($track.name.runs | ForEach-Object { $_.text }) -join ''
            } else {
                $track.name.simpleText
            }
            $langCode = [string]$track.languageCode
            $kind = [string]$track.kind
            $isEnglish = if ($langCode) {
                $langCode -match '^en(?:-|$)'
            } else {
                $name -match 'English'
            }
            $isAuto = if ($langCode) {
                ($kind -eq 'asr') -or ($name -match 'auto-generated')
            } else {
                ($kind -eq 'asr') -or ($name -ne 'English')
            }
            $rank = if ($isEnglish -and -not $isAuto) { 0 } elseif ($isEnglish) { 1 } else { 2 }
            $cleanLink = if ($null -ne $track.baseUrl) {
                ($track.baseUrl -replace '([?&])fmt=srv3&', '$1' -replace '[?&]fmt=srv3$', '')
            } else {
                $null
            }

            [PSCustomObject]@{
                Rank   = $rank
                Option = [PSCustomObject]@{
                    title       = $innertubeData.videoDetails.title
                    description = $innertubeData.videoDetails.shortDescription
                    language    = $name
                    link        = $cleanLink
                }
            }
        }

        return @($rankedTracks | Sort-Object -Stable -Property Rank | ForEach-Object { $_.Option })
    } catch {
        throw "Failed to retrieve caption tracks: $($_.Exception.Message)"
    }
}

function Get-RawTranscript {
    <#
    .SYNOPSIS
    Downloads and parses raw caption segments from a YouTube timedtext URL.

    .DESCRIPTION
    Validates that the supplied caption URL targets YouTube's HTTPS /api/timedtext endpoint, fetches the XML payload without following cross-origin redirects, prohibits DTD processing, and returns an array of caption segment objects with start, duration (in seconds as strings), and HTML-decoded text.

    .PARAMETER link
    A relative /api/timedtext path or full https://www.youtube.com/api/timedtext URL.

    .EXAMPLE
    $tracks = Get-LangOptionsWithLink -videoId 'GikIJpUv6oo'
    Get-RawTranscript -link $tracks[0].link
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$link
    )

    $uri = Resolve-PSYTTimedtextUri -Link $link

    # Align request behavior with youtube-transcript-api: keep cookies + headers consistent, and validate response before parsing XML.
    $session = Get-PSYTWebSession
    $headers = Get-PSYTRequestHeader

    $request = @{
        Uri                      = $uri
        WebSession               = $session
        Headers                  = $headers
        SkipHttpErrorCheck       = $true
        MaximumRedirection       = 0
        ConnectionTimeoutSeconds = 15
        OperationTimeoutSeconds  = 30
        ErrorAction              = 'Stop'
    }
    $previousMaxRedirection = $session.MaximumRedirection
    try {
        $transcriptPageResponse = Invoke-WebRequest @request
    } finally {
        $session.MaximumRedirection = $previousMaxRedirection
    }

    if ($transcriptPageResponse.StatusCode -eq 429) {
        throw 'YouTube is rate-limiting or blocking requests (HTTP 429) when fetching timedtext. Try again later or from a different network/IP.'
    }

    if ($transcriptPageResponse.StatusCode -lt 200 -or $transcriptPageResponse.StatusCode -ge 300) {
        throw "Failed to fetch transcript (HTTP $($transcriptPageResponse.StatusCode))."
    }

    $content = $transcriptPageResponse.Content
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw 'Timedtext returned an empty response body. This usually means the request was blocked, the caption URL expired, or captions are unavailable.'
    }

    $trimmed = $content.TrimStart()
    if ($trimmed.StartsWith('<!DOCTYPE html', [System.StringComparison]::OrdinalIgnoreCase) -or
        $trimmed.StartsWith('<html', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($trimmed -match 'class="g-recaptcha"' -or $trimmed -match 'Sign in to confirm you.?re not a bot') {
            throw 'YouTube is blocking this request with a bot/recaptcha page. Try again later or from a different network/IP.'
        }
        $snippet = ($trimmed.Substring(0, [Math]::Min(250, $trimmed.Length))).Replace("`r", ' ').Replace("`n", ' ')
        throw "Expected transcript XML but received HTML instead (likely consent/blocked page). First bytes: $snippet"
    }

    $xmlDoc = [System.Xml.XmlDocument]::new()
    $xmlDoc.XmlResolver = $null
    $readerSettings = [System.Xml.XmlReaderSettings]::new()
    $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $readerSettings.XmlResolver = $null
    $readerSettings.IgnoreComments = $true
    $readerSettings.IgnoreProcessingInstructions = $true

    try {
        $stringReader = [System.IO.StringReader]::new($content)
        try {
            $xmlReader = [System.Xml.XmlReader]::Create($stringReader, $readerSettings)
            try {
                $xmlDoc.Load($xmlReader)
            } finally {
                $xmlReader.Dispose()
            }
        } finally {
            $stringReader.Dispose()
        }
    } catch {
        if ($trimmed -match 'class="g-recaptcha"' -or $trimmed -match 'Sign in to confirm you.?re not a bot') {
            throw 'YouTube is blocking this request with a bot/recaptcha page. Try again later or from a different network/IP.'
        }
        $snippet = ($trimmed.Substring(0, [Math]::Min(250, $trimmed.Length))).Replace("`r", ' ').Replace("`n", ' ')
        throw "Failed to parse transcript XML: $($_.Exception.Message). First bytes: $snippet"
    }

    if ($xmlDoc.DocumentElement.Name -ne 'transcript') {
        if ($trimmed -match 'class="g-recaptcha"' -or $trimmed -match 'Sign in to confirm you.?re not a bot') {
            throw 'YouTube is blocking this request with a bot/recaptcha page. Try again later or from a different network/IP.'
        }
        throw 'Expected transcript XML but received an unexpected root element.'
    }

    $elementChildren = @($xmlDoc.DocumentElement.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
    $textNodes = @($elementChildren | Where-Object { $_.Name -eq 'text' })
    if ($elementChildren.Count -gt 0 -and $textNodes.Count -eq 0) {
        throw 'Expected transcript XML with <text> caption elements.'
    }

    $transcriptParts = @(
        foreach ($node in $textNodes) {
            [PSCustomObject]@{
                start    = $node.GetAttribute('start')
                duration = $node.GetAttribute('dur')
                text     = [System.Net.WebUtility]::HtmlDecode($node.InnerText)
            }
        }
    )

    return $transcriptParts
}

function ConvertTo-PSYTMarkdown {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject]$VideoInfo
    )

    $lines = @(
        '# Video Transcript'
        if ($VideoInfo.PSObject.Properties['title']) {
            '## Title'
            $VideoInfo.title
        }
        if ($VideoInfo.PSObject.Properties['description']) {
            '## Description'
            $VideoInfo.description
        }
        '## Language'
        $VideoInfo.language
        '## Transcript'
        '| Start    | Duration | Text |'
        '| :------- | :------ | :------ |'
        foreach ($part in $VideoInfo.transcript) {
            $text = ([string]$part.text).Replace('\', '\\').Replace('|', '\|') -replace '\r\n|\r|\n', '<br>'
            "| $($part.start) | $($part.duration) | $text |"
        }
    )
    return ($lines -join "`n") + "`n"
}

function Get-Transcript {
    <#
    .SYNOPSIS
    Retrieves the transcript for a YouTube video.

    .DESCRIPTION
    Fetches the preferred caption track (manual English first, then auto-generated English, then other available tracks) and formats it as Markdown (default), a structured PSObject, or a single plain-text string. Throws an error if the video ID/URL is invalid, the video is unavailable, or YouTube rejects the request. Returns no output for a playable video that has no captions.

    .PARAMETER videoId
    A YouTube video ID (11 characters) or supported YouTube URL (youtube.com, m.youtube.com, music.youtube.com, or youtu.be).

    .PARAMETER IncludeTitle
    Includes the video title in Markdown and PSObject output. Ignored when OutputFormat is Text.

    .PARAMETER IncludeDescription
    Includes the video description in Markdown and PSObject output. Ignored when OutputFormat is Text.

    .PARAMETER OutputFormat
    Controls the return format: Markdown (default), PSObject, or Text.

    .EXAMPLE
    Get-Transcript -videoId 'https://youtu.be/GikIJpUv6oo'

    .EXAMPLE
    Get-Transcript -videoId 'GikIJpUv6oo' -IncludeTitle -IncludeDescription -OutputFormat PSObject

    .EXAMPLE
    Get-Transcript -videoId 'GikIJpUv6oo' -OutputFormat Text

    .LINK
    https://github.com/litef00t/PSYT
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$videoId,
        [switch]$IncludeTitle,
        [switch]$IncludeDescription,
        [ValidateSet('PSObject', 'Markdown', 'Text')]
        [string]$OutputFormat = 'Markdown'
    )
    $vidId = Test-YouTubeVideoId -InputString $videoId
    if (-not $vidId) {
        throw 'Provide a valid YouTube video ID or URL.'
    }
    $langOptLinks = @(Get-LangOptionsWithLink -videoId $vidId)
    if ($langOptLinks.Count -eq 0) {
        Write-Verbose 'No transcripts available for this video.'
        return @()
    }

    $track = $langOptLinks[0]
    if (-not $track.link) {
        throw 'The selected caption track has no transcript URL.'
    }

    $videoInfo = [ordered]@{}
    if ($IncludeTitle) {
        $videoInfo.title = $track.title
    }
    if ($IncludeDescription) {
        $videoInfo.description = $track.description
    }
    $videoInfo.language = $track.language
    $videoInfo.transcript = @(Get-RawTranscript -link $track.link)

    if ($OutputFormat -eq 'Text') {
        return (($videoInfo.transcript.text -join ' ') -replace '\s+', ' ').Trim()
    }
    if ($OutputFormat -eq 'PSObject') {
        return [PSCustomObject]$videoInfo
    }
    return ConvertTo-PSYTMarkdown -VideoInfo ([PSCustomObject]$videoInfo)
}
