BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..' 'PSYT.psd1') -Force
}

Describe 'Module manifest and help' {
    It 'Passes Test-ModuleManifest and exports the expected public commands' {
        $manifest = Test-ModuleManifest -Path (Join-Path $PSScriptRoot '..' 'PSYT.psd1') -ErrorAction Stop
        $manifest.PowerShellVersion | Should -Be ([version]'7.4')
        ($manifest.ExportedFunctions.Keys | Sort-Object) | Should -Be @(
            'Get-LangOptionsWithLink'
            'Get-RawTranscript'
            'Get-Transcript'
            'Get-VideoPageHtml'
        )
    }

    It 'Provides comment-based help for exported commands: <CommandName>' -ForEach @(
        @{ CommandName = 'Get-VideoPageHtml' }
        @{ CommandName = 'Get-LangOptionsWithLink' }
        @{ CommandName = 'Get-RawTranscript' }
        @{ CommandName = 'Get-Transcript' }
    ) {
        $help = Get-Help -Name $CommandName
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -BeLike "*$CommandName*"
    }
}

Describe 'Caption selection' {
    InModuleScope PSYT {
        BeforeEach {
            Mock Get-VideoPageHtml { '"INNERTUBE_API_KEY":"test-key"' }
            Mock Get-PSYTInnertubeData {
                [PSCustomObject]@{
                    playabilityStatus = @{ status = 'OK' }
                    videoDetails      = @{ title = 'Example'; shortDescription = 'Description' }
                    captions          = @{
                        playerCaptionsTracklistRenderer = @{
                            captionTracks = @(
                                @{ name = @{ simpleText = 'French' }; baseUrl = '/api/timedtext?lang=fr' }
                                @{ name = @{ runs = @(@{ text = 'English' }, @{ text = ' (auto-generated)' }) }; baseUrl = '/api/timedtext?lang=en&kind=asr' }
                                @{ name = @{ simpleText = 'English' }; baseUrl = '/api/timedtext?x=1&fmt=srv3' }
                                @{ name = @{ simpleText = 'English' }; baseUrl = '/api/timedtext?lang=en2' }
                            )
                        }
                    }
                }
            }
        }

        It 'Prefers manual English and keeps each name paired with its own URL' {
            $tracks = @(Get-LangOptionsWithLink -videoId 'GikIJpUv6oo')
            $tracks.Count | Should -Be 4
            ($tracks.link -join ',') | Should -Be '/api/timedtext?x=1,/api/timedtext?lang=en2,/api/timedtext?lang=en&kind=asr,/api/timedtext?lang=fr'
            $tracks[2].language | Should -Be 'English (auto-generated)'
            $tracks[0].title | Should -Be 'Example'
            $tracks[0].description | Should -Be 'Description'
        }

        It 'Prefers manual English regional variants over auto-generated English using languageCode and kind' {
            Mock Get-PSYTInnertubeData {
                [PSCustomObject]@{
                    playabilityStatus = @{ status = 'OK' }
                    videoDetails      = @{ title = 'Example'; shortDescription = 'Description' }
                    captions          = @{
                        playerCaptionsTracklistRenderer = @{
                            captionTracks = @(
                                @{ languageCode = 'fr'; name = @{ simpleText = 'French' }; baseUrl = '/api/timedtext?lang=fr' }
                                @{ languageCode = 'en'; kind = 'asr'; name = @{ simpleText = 'English (auto-generated)' }; baseUrl = '/api/timedtext?fmt=srv3&lang=en-asr' }
                                @{ languageCode = 'en-US'; name = @{ simpleText = 'English (United States)' }; baseUrl = '/api/timedtext?x=1&fmt=srv3&y=2' }
                            )
                        }
                    }
                }
            }

            $tracks = @(Get-LangOptionsWithLink -videoId 'GikIJpUv6oo')
            $tracks.Count | Should -Be 3
            $tracks[0].language | Should -Be 'English (United States)'
            $tracks[0].link | Should -Be '/api/timedtext?x=1&y=2'
            $tracks[1].language | Should -Be 'English (auto-generated)'
            $tracks[1].link | Should -Be '/api/timedtext?lang=en-asr'
            $tracks[2].language | Should -Be 'French'
        }

        It 'Strips standalone ?fmt=srv3 parameter cleanly' {
            Mock Get-PSYTInnertubeData {
                [PSCustomObject]@{
                    playabilityStatus = @{ status = 'OK' }
                    videoDetails      = @{ title = 'Example'; shortDescription = 'Description' }
                    captions          = @{
                        playerCaptionsTracklistRenderer = @{
                            captionTracks = @(
                                @{ languageCode = 'en'; name = @{ simpleText = 'English' }; baseUrl = '/api/timedtext?fmt=srv3' }
                            )
                        }
                    }
                }
            }

            $tracks = @(Get-LangOptionsWithLink -videoId 'GikIJpUv6oo')
            $tracks[0].link | Should -Be '/api/timedtext'
        }

        It 'Returns no tracks when captions are absent' {
            Mock Get-PSYTInnertubeData { [PSCustomObject]@{ playabilityStatus = @{ status = 'OK' }; captions = $null } }
            @(Get-LangOptionsWithLink -videoId 'GikIJpUv6oo').Count | Should -Be 0
        }
    }
}

Describe 'Transcript output' {
    InModuleScope PSYT {
        BeforeEach {
            Mock Get-LangOptionsWithLink {
                [PSCustomObject]@{ title = 'Example'; description = 'Description'; language = 'English'; link = '/api/timedtext?lang=en' }
            }
            Mock Get-RawTranscript {
                [PSCustomObject]@{ start = '0'; duration = '1.5'; text = "one | two`nnext" }
            }
        }

        It 'Returns the original caption text in object mode as an array without formatting Markdown' {
            Mock ConvertTo-PSYTMarkdown { throw 'Formatter must not run' }
            $result = Get-Transcript -videoId 'GikIJpUv6oo' -OutputFormat PSObject -IncludeTitle -IncludeDescription
            $result.title | Should -Be 'Example'
            $result.description | Should -Be 'Description'
            $result.language | Should -Be 'English'
            ($result.transcript -is [array]) | Should -BeTrue
            $result.transcript.Count | Should -Be 1
            $result.transcript[0].text | Should -Be "one | two`nnext"
            Should -Invoke Get-RawTranscript -Times 1 -Exactly -ParameterFilter { $link -eq '/api/timedtext?lang=en' }
        }

        It 'Omits optional object properties unless requested' {
            $result = Get-Transcript -videoId 'GikIJpUv6oo' -OutputFormat PSObject
            ($result.PSObject.Properties.Name -join ',') | Should -Be 'language,transcript'
        }

        It 'Returns one plain-text paragraph without metadata or Markdown escaping' {
            Mock ConvertTo-PSYTMarkdown { throw 'Formatter must not run' }
            Mock Get-RawTranscript {
                [PSCustomObject]@{ start = '0'; duration = '1'; text = "  First | line`r`nnext " }
                [PSCustomObject]@{ start = '1'; duration = '2'; text = " second`tpart.  " }
            }
            $result = Get-Transcript -videoId 'GikIJpUv6oo' -OutputFormat Text -IncludeTitle -IncludeDescription
            $result | Should -BeOfType ([string])
            $result | Should -Be 'First | line next second part.'
            Should -Invoke Get-RawTranscript -Times 1 -Exactly
        }

        It 'Returns text for a single caption' {
            Get-Transcript -videoId 'GikIJpUv6oo' -OutputFormat Text | Should -Be 'one | two next'
        }

        It 'Returns an empty string for an empty transcript in text mode' {
            Mock Get-RawTranscript { @() }
            $result = Get-Transcript -videoId 'GikIJpUv6oo' -OutputFormat Text
            $result | Should -BeOfType ([string])
            $result | Should -Be ''
        }

        It 'Defaults to Markdown and keeps pipes and newlines inside the text cell' {
            $result = Get-Transcript -videoId 'GikIJpUv6oo'
            $result | Should -BeOfType ([string])
            $result | Should -BeLike '*| 0 | 1.5 | one \| two<br>next |*'
            $result | Should -Not -BeLike '*## Title*'
            $result | Should -Not -BeLike '*## Description*'
        }

        It 'Includes requested metadata in Markdown' {
            $result = Get-Transcript -videoId 'GikIJpUv6oo' -IncludeTitle -IncludeDescription
            $result | Should -BeLike "*## Title`nExample`n## Description`nDescription`n*"
        }

        It 'Formats all segments in order' {
            Mock Get-RawTranscript {
                [PSCustomObject]@{ start = '0'; duration = '1'; text = 'First' }
                [PSCustomObject]@{ start = '1'; duration = '2'; text = 'Second' }
            }
            $result = Get-Transcript -videoId 'GikIJpUv6oo'
            $result | Should -BeLike "*| 0 | 1 | First |`n| 1 | 2 | Second |`n"
        }

        It 'Does not fetch a transcript when there are no caption tracks' {
            Mock Get-LangOptionsWithLink { @() }
            @(Get-Transcript -videoId 'GikIJpUv6oo').Count | Should -Be 0
            Should -Invoke Get-RawTranscript -Times 0 -Exactly
        }

        It 'Does not fetch a transcript when the selected URL is missing' {
            Mock Get-LangOptionsWithLink { [PSCustomObject]@{ link = $null } }
            { Get-Transcript -videoId 'GikIJpUv6oo' } | Should -Throw '*no transcript URL*'
            Should -Invoke Get-RawTranscript -Times 0 -Exactly
        }

        It 'Rejects invalid input before looking up captions' {
            { Get-Transcript -videoId 'invalid' } | Should -Throw '*valid YouTube*'
            Should -Invoke Get-LangOptionsWithLink -Times 0 -Exactly
        }
    }
}

Describe 'Video ID parsing' {
    InModuleScope PSYT {
        It 'Accepts supported IDs and URLs: <Value>' -ForEach @(
            @{ Value = 'GikIJpUv6oo' }
            @{ Value = 'https://youtu.be/GikIJpUv6oo?t=12' }
            @{ Value = 'https://youtu.be/GikIJpUv6oo?si=AbCdEfGhIjKlMnOp' }
            @{ Value = 'youtube.com/watch?v=GikIJpUv6oo&list=PLabcdefghijklmnop' }
            @{ Value = 'https://www.youtube.com/watch?v=GikIJpUv6oo&feature=emb_rel_end' }
            @{ Value = 'https://www.youtube.com/watch?list=abc&v=GikIJpUv6oo' }
            @{ Value = 'https://music.youtube.com/watch?v=GikIJpUv6oo' }
            @{ Value = 'https://m.youtube.com/shorts/GikIJpUv6oo' }
            @{ Value = 'https://www.youtube.com/shorts/GikIJpUv6oo/' }
            @{ Value = 'https://www.youtube.com/live/GikIJpUv6oo' }
            @{ Value = 'https://www.youtube.com/embed/GikIJpUv6oo' }
            @{ Value = 'https://www.youtube.com/v/GikIJpUv6oo' }
        ) {
            Test-YouTubeVideoId -InputString $Value | Should -Be 'GikIJpUv6oo'
        }

        It 'Rejects invalid input: <Value>' -ForEach @(
            @{ Value = '' }
            @{ Value = 'invalid' }
            @{ Value = 'https://example.com/youtube.com/watch?v=GikIJpUv6oo' }
            @{ Value = 'https://notyoutube.com/watch?v=GikIJpUv6oo' }
            @{ Value = 'https://www.youtube.com.attacker.com/watch?v=GikIJpUv6oo' }
            @{ Value = 'https://www.youtube.com:8443/watch?v=GikIJpUv6oo' }
            @{ Value = 'https://user@www.youtube.com/watch?v=GikIJpUv6oo' }
            @{ Value = 'https://youtu.be/GikIJpUv6ooExtra' }
            @{ Value = 'https://youtube.com/watch?v=GikIJpUv6ooExtra' }
            @{ Value = "GikIJpUv6oo`n" }
            @{ Value = "https://youtu.be/GikIJpUv6oo`n" }
            @{ Value = "https://www.youtube.com/watch?v=GikIJpUv6oo`n" }
            @{ Value = 'https://www.youtube.com/watch?v=GikIJpUv6oo%0A' }
            @{ Value = 'abcdefghijé' }
        ) {
            @(Test-YouTubeVideoId -InputString $Value).Count | Should -Be 0
        }
    }
}

Describe 'Fetch failures and hardening' {
    InModuleScope PSYT {
        BeforeEach {
            $script:PSYT_WebSession = $null
            Mock Invoke-WebRequest { throw 'Unexpected web request' }
            Mock Invoke-RestMethod { throw 'HTTP 403' }
        }

        It 'Rejects invalid input to exported helpers before requesting a page' {
            { Get-VideoPageHtml -videoId 'invalid' } | Should -Throw '*valid YouTube*'
            { Get-LangOptionsWithLink -videoId 'invalid' } | Should -Throw '*valid YouTube*'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'Preserves a page request failure' {
            Mock Invoke-WebRequest { throw 'HTTP 429' }
            { Get-VideoPageHtml -videoId 'GikIJpUv6oo' } | Should -Throw '*HTTP 429*'
        }

        It 'Detects a bot page without video metadata' {
            Mock Invoke-WebRequest { @{ Content = '<div class="g-recaptcha">' } }
            { Get-VideoPageHtml -videoId 'GikIJpUv6oo' } | Should -Throw '*bot/recaptcha*'
        }

        It 'Does not false-positive when a valid video page mentions bot text' {
            Mock Invoke-WebRequest { @{ Content = '<meta property="og:url" content="x"> "playabilityStatus":{} Sign in to confirm you''re not a bot' } }
            Get-VideoPageHtml -videoId 'GikIJpUv6oo' | Should -BeLike '*playabilityStatus*'
        }

        It 'Retries consent once and returns the video page' {
            Mock Invoke-WebRequest { @{ Content = 'action="https://consent.youtube.com/s" name="v" value="test"' } }
            Mock Invoke-WebRequest { @{ Content = 'og:url "playabilityStatus":{}' } } -ParameterFilter {
                $WebSession.Cookies.GetCookies([Uri]'https://www.youtube.com')['CONSENT']
            }
            $script:PSYT_WebSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            Get-VideoPageHtml -videoId 'GikIJpUv6oo' | Should -Be 'og:url "playabilityStatus":{}'
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        }

        It 'Stops after one unsuccessful consent retry' {
            Mock Invoke-WebRequest { @{ Content = 'action="https://consent.youtube.com/s" name="v" value="test"' } }
            { Get-VideoPageHtml -videoId 'GikIJpUv6oo' } | Should -Throw '*still requires consent*'
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        }

        It 'Reports a missing API key' {
            Mock Get-VideoPageHtml { 'og:url "playabilityStatus":{}' }
            { Get-LangOptionsWithLink -videoId 'GikIJpUv6oo' } | Should -Throw '*API key*'
        }

        It 'Preserves a player request failure' {
            Mock Get-VideoPageHtml { '"INNERTUBE_API_KEY":"test-key"' }
            { Get-LangOptionsWithLink -videoId 'GikIJpUv6oo' } | Should -Throw '*HTTP 403*'
        }

        It 'Distinguishes an unavailable video from missing captions' {
            Mock Get-VideoPageHtml { '"INNERTUBE_API_KEY":"test-key"' }
            Mock Get-PSYTInnertubeData { @{ playabilityStatus = @{ status = 'ERROR'; reason = 'Video removed' } } }
            { Get-LangOptionsWithLink -videoId 'GikIJpUv6oo' } | Should -Throw '*Video removed*'
        }

        It 'Rejects a malformed player response' {
            Mock Get-VideoPageHtml { '"INNERTUBE_API_KEY":"test-key"' }
            Mock Get-PSYTInnertubeData { @{} }
            { Get-LangOptionsWithLink -videoId 'GikIJpUv6oo' } | Should -Throw '*missing playability status*'
        }

        It 'Rejects untrusted or invalid transcript URLs before sending a request: <Link>' -ForEach @(
            @{ Link = '' }
            @{ Link = 'https://www.youtube.com.attacker.com/api/timedtext?v=GikIJpUv6oo' }
            @{ Link = '//attacker.com/api/timedtext?v=GikIJpUv6oo' }
            @{ Link = 'http://www.youtube.com/api/timedtext?v=GikIJpUv6oo' }
            @{ Link = 'https://www.youtube.com/watch?v=GikIJpUv6oo' }
        ) {
            { Get-RawTranscript -link $Link } | Should -Throw '*Invalid transcript URL*'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'Accepts https://youtube.com/api/timedtext URLs without www' {
            Mock Invoke-WebRequest { @{ StatusCode = 200; Content = '<transcript><text start="0" dur="1">Hi</text></transcript>' } } -ParameterFilter {
                $Uri -eq 'https://youtube.com/api/timedtext?v=GikIJpUv6oo'
            }
            $result = @(Get-RawTranscript -link 'https://youtube.com/api/timedtext?v=GikIJpUv6oo')
            $result.Count | Should -Be 1
            $result[0].text | Should -Be 'Hi'
        }

        It 'Rejects failed or redirected transcript responses: <Status>' -ForEach @(
            @{ Status = 302 }
            @{ Status = 429 }
            @{ Status = 403 }
            @{ Status = 500 }
        ) {
            Mock Invoke-WebRequest { @{ StatusCode = $Status; Content = '<transcript />' } }
            { Get-RawTranscript -link '/api/timedtext' } | Should -Throw "*HTTP $Status*"
        }

        It 'Rejects XML documents containing DTDs' {
            Mock Invoke-WebRequest {
                @{
                    StatusCode = 200
                    Content    = '<!DOCTYPE transcript [<!ENTITY lol "lol">]><transcript><text start="0" dur="1">&lol;</text></transcript>'
                }
            }
            { Get-RawTranscript -link '/api/timedtext' } | Should -Throw '*DTD*'
        }

        It 'Rejects unexpected XML instead of returning empty transcript entries' {
            Mock Invoke-WebRequest { @{ StatusCode = 200; Content = '<error><message>Blocked</message></error>' } }
            { Get-RawTranscript -link '/api/timedtext' } | Should -Throw '*unexpected root*'
        }

        It 'Rejects transcript XML with non-text element children' {
            Mock Invoke-WebRequest { @{ StatusCode = 200; Content = '<transcript><error>Blocked</error></transcript>' } }
            { Get-RawTranscript -link '/api/timedtext' } | Should -Throw '*<text>*'
        }

        It 'Ignores XML comments and decodes valid transcript XML' {
            Mock Invoke-WebRequest { @{ StatusCode = 200; Content = '<transcript><!-- comment --><text start="0" dur="1">A &amp;amp; B</text></transcript>' } }
            $result = @(Get-RawTranscript -link '/api/timedtext')
            $result.Count | Should -Be 1
            $result[0].text | Should -Be 'A & B'
            $result[0].start | Should -Be '0'
            $result[0].duration | Should -Be '1'
        }

        It 'Allows valid transcript captions that quote bot-check text' {
            Mock Invoke-WebRequest {
                @{
                    StatusCode = 200
                    Content    = '<transcript><text start="0" dur="2">Sign in to confirm you''re not a bot</text></transcript>'
                }
            }
            $result = @(Get-RawTranscript -link '/api/timedtext')
            $result.Count | Should -Be 1
            $result[0].text | Should -Be "Sign in to confirm you're not a bot"
        }

        It 'Reports a bot page when timedtext returns an HTML recaptcha interstitial' {
            Mock Invoke-WebRequest {
                @{
                    StatusCode = 200
                    Content    = '<!DOCTYPE html><html><body><div class="g-recaptcha"></div></body></html>'
                }
            }
            { Get-RawTranscript -link '/api/timedtext' } | Should -Throw '*bot/recaptcha*'
        }

        It 'Restores WebRequestSession.MaximumRedirection after both successful and redirected caption fetches' {
            $script:PSYT_WebSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
            $originalMax = $script:PSYT_WebSession.MaximumRedirection
            $originalMax | Should -Not -Be 0

            Mock Invoke-WebRequest {
                $WebSession.MaximumRedirection = $MaximumRedirection
                @{ StatusCode = 200; Content = '<transcript><text start="0" dur="1">Ok</text></transcript>' }
            }
            @(Get-RawTranscript -link '/api/timedtext').Count | Should -Be 1
            $script:PSYT_WebSession.MaximumRedirection | Should -Be $originalMax

            Mock Invoke-WebRequest {
                $WebSession.MaximumRedirection = $MaximumRedirection
                throw 'The maximum redirection count has been exceeded.'
            }
            { Get-RawTranscript -link '/api/timedtext' } | Should -Throw '*maximum redirection*'
            $script:PSYT_WebSession.MaximumRedirection | Should -Be $originalMax
        }
    }
}
