BeforeDiscovery {
    Import-Module "$PSScriptRoot/../PSYT.psd1" -Force
}

Describe 'Caption selection' {
    InModuleScope PSYT {
        BeforeEach {
            Mock Get-VideoPageHtml { '"INNERTUBE_API_KEY":"test-key"' }
            Mock Get-PSYTInnertubeData {
                [PSCustomObject]@{
                    playabilityStatus = @{ status = 'OK' }
                    videoDetails = @{ title = 'Example'; shortDescription = 'Description' }
                    captions = @{
                        playerCaptionsTracklistRenderer = @{
                            captionTracks = @(
                                @{ name = @{ simpleText = 'French' }; baseUrl = '/french' }
                                @{ name = @{ runs = @(@{ text = 'English' }, @{ text = ' (auto-generated)' }) }; baseUrl = '/auto' }
                                @{ name = @{ simpleText = 'English' }; baseUrl = '/manual?x=1&fmt=srv3' }
                                @{ name = @{ simpleText = 'English' }; baseUrl = '/second' }
                            )
                        }
                    }
                }
            }
        }

        It 'Prefers manual English and keeps each name paired with its own URL' {
            $tracks = @(Get-LangOptionsWithLink -videoId 'GikIJpUv6oo')
            $tracks.Count | Should -Be 4
            ($tracks.link -join ',') | Should -Be '/manual?x=1,/second,/auto,/french'
            $tracks[2].language | Should -Be 'English (auto-generated)'
            $tracks[0].title | Should -Be 'Example'
            $tracks[0].description | Should -Be 'Description'
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
                [PSCustomObject]@{ title = 'Example'; description = 'Description'; language = 'English'; link = '/manual' }
            }
            Mock Get-RawTranscript {
                [PSCustomObject]@{ start = '0'; duration = '1.5'; text = "one | two`nnext" }
            }
        }

        It 'Returns the original caption text in object mode without formatting Markdown' {
            Mock ConvertTo-PSYTMarkdown { throw 'Formatter must not run' }
            $result = Get-Transcript -videoId 'GikIJpUv6oo' -OutputFormat PSObject -IncludeTitle -IncludeDescription
            $result.title | Should -Be 'Example'
            $result.description | Should -Be 'Description'
            $result.language | Should -Be 'English'
            $result.transcript.text | Should -Be "one | two`nnext"
            Should -Invoke Get-RawTranscript -Times 1 -Exactly -ParameterFilter { $link -eq '/manual' }
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
            @{ Value = 'youtube.com/watch?v=GikIJpUv6oo&list=abc' }
            @{ Value = 'https://www.youtube.com/watch?list=abc&v=GikIJpUv6oo' }
            @{ Value = 'https://m.youtube.com/shorts/GikIJpUv6oo' }
            @{ Value = 'https://www.youtube.com/embed/GikIJpUv6oo' }
            @{ Value = 'https://www.youtube.com/v/GikIJpUv6oo' }
        ) {
            Test-YouTubeVideoId -InputString $Value | Should -Be 'GikIJpUv6oo'
        }

        It 'Rejects invalid input: <Value>' -ForEach @(
            @{ Value = 'invalid' }
            @{ Value = 'https://example.com/youtube.com/watch?v=GikIJpUv6oo' }
            @{ Value = 'https://notyoutube.com/watch?v=GikIJpUv6oo' }
            @{ Value = 'https://youtu.be/GikIJpUv6ooExtra' }
            @{ Value = 'https://youtube.com/watch?v=GikIJpUv6ooExtra' }
            @{ Value = 'abcdefghijé' }
        ) {
            @(Test-YouTubeVideoId -InputString $Value).Count | Should -Be 0
        }
    }
}

Describe 'Fetch failures' {
    InModuleScope PSYT {
        BeforeEach {
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

        It 'Rejects failed transcript responses: <Status>' -ForEach @(
            @{ Status = 429 }
            @{ Status = 403 }
            @{ Status = 500 }
        ) {
            Mock Invoke-WebRequest { @{ StatusCode = $Status; Content = '<transcript />' } }
            { Get-RawTranscript -link '/api/timedtext' } | Should -Throw "*HTTP $Status*"
        }

        It 'Rejects unexpected XML instead of returning empty transcript entries' {
            Mock Invoke-WebRequest { @{ StatusCode = 200; Content = '<error><message>Blocked</message></error>' } }
            { Get-RawTranscript -link '/api/timedtext' } | Should -Throw '*unexpected root*'
        }

        It 'Still parses valid transcript XML' {
            Mock Invoke-WebRequest { @{ StatusCode = 200; Content = '<transcript><text start="0" dur="1">A &amp;amp; B</text></transcript>' } }
            $result = Get-RawTranscript -link '/api/timedtext'
            $result.text | Should -Be 'A & B'
            $result.start | Should -Be '0'
            $result.duration | Should -Be '1'
        }
    }
}
