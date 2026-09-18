<#
.SYNOPSIS
This module contains functions to work with YouTube video IDs and retrieve video transcripts.

.DESCRIPTION
The PSYT module provides functions to validate YouTube video IDs, retrieve the HTML content of a YouTube video page, get language options with links for video captions, and retrieve the transcript of a YouTube video.

.FUNCTIONS
1. Test-YouTubeVideoId
    - Validates a string to check if it contains a valid YouTube video ID.
    - Returns the video ID if found, or an empty array if no valid video ID is found.

2. Get-VideoPageHtml
    - Retrieves the HTML content of a YouTube video page using the video ID.
    - Returns the HTML content if successful, or throws if the request fails.

3. Get-LangOptionsWithLink
    - Retrieves the language options with links for video captions using the video ID.
    - Returns an array of objects containing the video title, description, language, and link for each language option.

4. Get-RawTranscript
    - Retrieves the raw transcript of a YouTube video using the caption link.
    - Returns an array of objects containing the start time, duration, and text of each transcript part.

5. Get-Transcript
    - Retrieves the transcript of a YouTube video using the video ID.
    - Returns Markdown by default, an object for PSObject, or caption text only for Text.
    - Optional parameters: IncludeTitle, IncludeDescription.


.PARAMETER videoId
The YouTube video ID or YouTube Url.

.PARAMETER IncludeTitle
Specifies whether to include the video title in the transcript object. Default is false.

.PARAMETER IncludeDescription
Specifies whether to include the video description in the transcript object. Default is false.

.EXAMPLE
PS C:\> Test-YouTubeVideoId -InputString "https://www.youtube.com/watch?v=vc79sJ9VOqk"
Returns: "vc79sJ9VOqk"

.EXAMPLE
PS C:\> Get-Transcript -videoId "GikIJpUv6oo" -IncludeTitle -IncludeDescription -OutputFormat PSObject
Returns: Object containing the video title, description, language, and transcript parts.

.NOTES
This module requires the Invoke-WebRequest cmdlet to be available.

.LINK
GitHub: https://github.com/Blindpete/PSYT

#>
function Test-YouTubeVideoId {
    param (
        [string]$InputString
    )

    # Accept only complete IDs or supported YouTube URLs.
    $pattern = '^(?:https?://)?(?:www\.|m\.)?(?:youtube\.com/(?:watch\?(?:[^#\s]*&)?v=|embed/|v/|shorts/)|youtu\.be/)(?<id>[A-Za-z0-9_-]{11})(?:[?&#][^\s]*)?$'

    if ($InputString -match $pattern) {
        $videoId = $matches['id']
        Write-Verbose "Valid YouTube video ID found: $videoId"
        return $videoId
    } elseif ($InputString -match '^[A-Za-z0-9_-]{11}$') {
        Write-Verbose "Valid YouTube video ID format: $InputString"
        return $InputString
    } else {
        Write-Verbose 'No valid YouTube video ID found in the string.'
        return @()
    }
}

function Get-PSYTWebSession {
    [CmdletBinding()]
    param()

    if (-not $script:PSYT_WebSession) {
        $script:PSYT_WebSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    }

    return $script:PSYT_WebSession
}

function Get-PSYTHeaders {
    [CmdletBinding()]
    param()

    # Keep this lightweight but "browser-like" enough for YouTube to return the expected payloads.
    return @{
        'Accept-Language' = 'en-US,en;q=0.9'
        'Accept'          = 'application/xml,text/xml,text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8'
        'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }
}

function Set-PSYTConsentCookie {
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
        Write-Debug "Failed to set CONSENT cookie: $($_.Exception.Message)"
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
        return Invoke-RestMethod -Method Post -Uri $uri -WebSession $WebSession -Headers $Headers -ContentType 'application/json' -Body $body -ErrorAction Stop
    } catch {
        throw "Failed to fetch Innertube player data: $($_.Exception.Message)"
    }
}

function Get-VideoPageHtml {
    param (
        [string]$videoId
    )

    $videoId = Test-YouTubeVideoId -InputString $videoId
    if (-not $videoId) {
        throw 'Provide a valid YouTube video ID or URL.'
    }
    try {
        $session = Get-PSYTWebSession
        $headers = Get-PSYTHeaders

        $request = @{
            Uri         = "https://www.youtube.com/watch?v=$videoId"
            WebSession  = $session
            Headers     = $headers
            ErrorAction = 'Stop'
        }
        $response = Invoke-WebRequest @request
        $html = $response.Content

        # If YouTube serves a consent page, set the CONSENT cookie and retry once (mirrors youtube-transcript-api behavior).
        if ($html -match 'action="https://consent\.youtube\.com/s"') {
            $consentMatch = [regex]::Match($html, 'name="v"\s+value="(.*?)"')
            if ($consentMatch.Success -and $consentMatch.Groups.Count -ge 2) {
                Set-PSYTConsentCookie -WebSession $session -ConsentValue $consentMatch.Groups[1].Value
                $response = Invoke-WebRequest @request
                $html = $response.Content
            } else {
                throw 'Could not resolve the YouTube consent page.'
            }

            if ($html -match 'action="https://consent\.youtube\.com/s"') {
                throw 'YouTube still requires consent after retrying.'
            }
        }
        if ($html -match 'class="g-recaptcha"|Sign in to confirm you.?re not a bot') {
            throw 'YouTube is blocking this request with a bot/recaptcha page.'
        }
        if ($html -notmatch 'og:url' -or $html -notmatch '"playabilityStatus":') {
            throw 'YouTube did not return the expected video page.'
        }
        return $html
    } catch {
        throw "Failed to fetch video page for ${videoId}: $($_.Exception.Message)"
    }
}

# Returns caption tracks with their URLs, preferring English over other languages.
function Get-LangOptionsWithLink {
    param (
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
    $headers = Get-PSYTHeaders

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

        $languageOptions = foreach ($track in $captions.captionTracks) {
            $name = if ($track.name.runs) { $track.name.runs.text -join '' } else { $track.name.simpleText }
            [PSCustomObject]@{
                title       = $innertubeData.videoDetails.title
                description = $innertubeData.videoDetails.shortDescription
                language    = $name
                link        = $track.baseUrl -replace '&fmt=srv3', ''
            }
        }

        return $languageOptions | Sort-Object -Stable {
            if ($_.language -eq 'English') { 0 }
            elseif ($_.language -match 'English') { 1 }
            else { 2 }
        }
    } catch {
        throw "Failed to retrieve caption tracks: $($_.Exception.Message)"
    }
}
function Get-RawTranscript {
    param (
        [string]$link
    )

    if (-not $link.StartsWith('https://www.youtube.com')) {
        $uri = ('https://www.youtube.com{0}' -f $link)
    } else {
        $uri = $link
    }

    # Align request behavior with youtube-transcript-api: keep cookies + headers consistent, and validate response before parsing XML.
    $session = Get-PSYTWebSession
    $headers = Get-PSYTHeaders

    $transcriptPageResponse = Invoke-WebRequest -Uri $uri -WebSession $session -Headers $headers -SkipHttpErrorCheck -ErrorAction Stop

    if ($transcriptPageResponse.StatusCode -eq 429) {
        throw "YouTube is rate-limiting or blocking requests (HTTP 429) when fetching timedtext. Try again later or from a different network/IP."
    }

    if ($transcriptPageResponse.StatusCode -lt 200 -or $transcriptPageResponse.StatusCode -ge 300) {
        throw "Failed to fetch transcript (HTTP $($transcriptPageResponse.StatusCode))."
    }

    $content = $transcriptPageResponse.Content
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Timedtext returned an empty response body. This usually means the request was blocked, the caption URL expired, or captions are unavailable."
    }

    $trimmed = $content.TrimStart()
    if ($trimmed.StartsWith('<!DOCTYPE html', [System.StringComparison]::OrdinalIgnoreCase) -or
        $trimmed.StartsWith('<html', [System.StringComparison]::OrdinalIgnoreCase)) {
        $snippet = ($trimmed.Substring(0, [Math]::Min(250, $trimmed.Length))).Replace("`r", ' ').Replace("`n", ' ')
        throw "Expected transcript XML but received HTML instead (likely consent/blocked page). First bytes: $snippet"
    }

    if ($trimmed -match 'class="g-recaptcha"' -or $trimmed -match "Sign in to confirm you.?re not a bot") {
        throw "YouTube is blocking this request with a bot/recaptcha page. Try again later or from a different network/IP."
    }

    $xmlDoc = New-Object System.Xml.XmlDocument
    try {
        $xmlDoc.LoadXml($content)
    } catch {
        $snippet = ($trimmed.Substring(0, [Math]::Min(250, $trimmed.Length))).Replace("`r", ' ').Replace("`n", ' ')
        throw "Failed to parse transcript XML: $($_.Exception.Message). First bytes: $snippet"
    }

    if ($xmlDoc.DocumentElement.Name -ne 'transcript') {
        throw 'Expected transcript XML but received an unexpected root element.'
    }
    $textNodes = $xmlDoc.documentElement.ChildNodes

    $transcriptParts = @()
    foreach ($node in $textNodes) {
        $transcriptParts += [PSCustomObject]@{
            start    = $node.GetAttribute('start')
            duration = $node.GetAttribute('dur')
            text     = [System.Web.HttpUtility]::HtmlDecode($node.InnerText)
        }
    }

    return $transcriptParts
}

# Formats a transcript object as Markdown, keeping caption text inside table cells.
function ConvertTo-PSYTMarkdown {
    param (
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

# Fetches the preferred caption track as Markdown, a transcript object, or plain text.
function Get-Transcript {
    param (
        [Parameter(Mandatory)]
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
    $videoInfo.transcript = Get-RawTranscript -link $track.link

    if ($OutputFormat -eq 'Text') {
        return (($videoInfo.transcript.text -join ' ') -replace '\s+', ' ').Trim()
    }
    if ($OutputFormat -eq 'PSObject') {
        return [PSCustomObject]$videoInfo
    }
    return ConvertTo-PSYTMarkdown -VideoInfo ([PSCustomObject]$videoInfo)
}
