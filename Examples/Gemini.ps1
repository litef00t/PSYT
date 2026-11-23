function Invoke-GeminiAI {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UserInput,

        [Parameter(Mandatory)]
        [string]$Instructions,

        [string]$Model = 'gemini-3.6-flash'
    )

    function Invoke-GeminiAPI {
        param(
            [string]$Instructions,
            [string]$UserInput,
            [string]$Model
        )

        $apiKey = $env:GeminiKey
        if (-not $apiKey) {
            Write-Error "API key is missing. Please set the 'GeminiKey' environment variable."
            return
        }

        $headers = @{
            'Content-Type'   = 'application/json'
            'x-goog-api-key' = $apiKey
        }

        $body = @{
            system_instruction = @{
                parts = @(
                    @{
                        text = $Instructions
                    }
                )
            }
            contents           = @(
                @{
                    role  = 'user'
                    parts = @(
                        @{
                            text = $UserInput
                        }
                    )
                }
            )
        } | ConvertTo-Json -Depth 6

        $url = "https://generativelanguage.googleapis.com/v1beta/models/${Model}:generateContent"

        try {
            return Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body -ErrorAction Stop
        } catch {
            Write-Error "Failed to invoke Gemini API: $_"
        }
    }

    # Check if 'glow' is available
    $useGlow = Get-Command -Name glow -ErrorAction SilentlyContinue

    $response = Invoke-GeminiAPI -Instructions $Instructions -UserInput $UserInput -Model $Model
    if (-not $response) {
        return
    }

    $contentText = if ($response.candidates -and $response.candidates.Count -gt 0 -and
        $response.candidates[0].content -and $response.candidates[0].content.parts -and $response.candidates[0].content.parts.Count -gt 0) {
        $response.candidates[0].content.parts[0].text
    }

    if ($contentText) {
        if ($useGlow) {
            $contentText | glow
        } else {
            $contentText
        }
    } else {
        Write-Error 'Gemini API returned no candidate text.'
    }
}

Import-Module (Join-Path $PSScriptRoot '..' 'PSYT.psd1') -Force

$instructions = @'
Summarize the key points of this video transcript.
'@

# Source: https://www.youtube.com/watch?v=7hNbYOjh-1k
$geminiParams = @{
    Instructions = $instructions
    UserInput    = (Get-Transcript -videoId '7hNbYOjh-1k' -IncludeTitle -IncludeDescription)
}

Invoke-GeminiAI @geminiParams
