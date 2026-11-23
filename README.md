# PSYT

![drawing](Media/PSYT.png)

## PowerShell Module for Retrieving YouTube Transcripts

Requires **PowerShell 7.4+**.

### Using the Module

```powershell
Install-Module -Name PSYT
```

For just the transcript as one plain-text string:

```powershell
Get-Transcript -videoId 'https://youtu.be/0oXOOlqVu5M' -OutputFormat Text
```

`Text` joins captions with spaces and collapses whitespace into a single paragraph. It omits timestamps and metadata, even when `IncludeTitle` or `IncludeDescription` is supplied. The default output remains `Markdown`; use `PSObject` for structured data.

### Example

Requirements:

- [PSAI Module](https://github.com/dfinke/psai)
- [OpenAI API Key](https://help.openai.com/en/articles/4936850-where-do-i-find-my-openai-api-key)

In this example, we will retrieve the transcript of a YouTube video and then generate a summary of the main points and key takeaways from the transcript using the GPT-4o-mini model.

```powershell
# Source: https://youtu.be/OHQFObW6PXA
$transcriptParams = @{
    videoId            = 'OHQFObW6PXA'
    IncludeTitle       = $true
    IncludeDescription = $true
    OutputFormat       = 'PSObject'
}

$transcript = Get-Transcript @transcriptParams

$summaryInput = @"
# Title:
$($transcript.title)

# Description:
$($transcript.description)

# Transcript:
$(($transcript.transcript | ForEach-Object { "[$($_.start)s] $($_.text)" }) -join "`n")
"@

$summaryParams = @{
    Instructions = 'Write a concise summary of the video transcript with 3-5 bullet points that highlight the key points or takeaways from the video transcript, include the title and details from the description.'
    model        = 'gpt-4o-mini'
    UserInput    = $summaryInput
}

$summary = ai @summaryParams
$summary | glow
```

### Output

### Summary of "AI Development for a Non-Developer"

- **Introduction to Generative AI**: The video guides non-developers on utilizing GPT models and explains the basics of AI application development using Python.

- **Setting Up the Environment**: Instructions on installing Python, necessary libraries (like Azure Identity and OpenAI API), and the Azure CLI to set up the development environment.

- **Creating and Deploying Models**: The video details the process of creating an OpenAI resource in Azure, deploying a GPT model, and using Azure AI Studio for model management.

- **Building a Simple GPT Application**: Steps to create a text-based application for interacting with the GPT model, including managing user input, tracking memory of interactions, and handling tokens effectively.

- **Final Thoughts**: Emphasis on the simplicity of the coding process, encouragement to explore AI tools like Copilot and GPT for coding assistance, and the importance of using orchestration tools for more complex development in the future.

---

### TODO

- [ ] Add more examples
- [x] Fix encode issue
- [x] Add getting video description
- [x] Add getting video title
- [ ] Add getting video chapters

### Tests and publishing

The GitHub Actions workflow validates `PSYT.psd1`, runs `PSScriptAnalyzer`, and runs Pester 5 tests (`*.Tests.ps1`) on both Windows and Linux for pull requests, pushes to `main`, `v*` tags, and manual runs.

To publish a release to PowerShell Gallery:

1. Bump `ModuleVersion` in `PSYT.psd1` and update `changelog.md` via PR to `main`.
2. Push a matching tag (for example, `v0.3.1`) or trigger the workflow manually via `workflow_dispatch` on `main`.

Add a repository Actions secret named `PSGALLERY_API_KEY` containing a Gallery API key with permission to publish PSYT. When triggered by a `v*` tag, the workflow verifies that the tag matches `PSYT.psd1`'s `ModuleVersion` before publishing.

### Notes / Troubleshooting

- Invalid video IDs, failed requests, unavailable videos, and malformed responses throw errors that callers can catch with `try` / `catch`. A playable video with no captions returns no output.
- The module reuses a single `WebRequestSession` for the lifetime of the module import so YouTube consent cookies persist across requests.
- The module fetches caption-track metadata via YouTube's Innertube player API (mirroring `youtube-transcript-api`) to avoid stale/blocked caption URLs.
- If you see errors like **HTTP 429**, **bot/recaptcha**, or **Expected transcript XML but received HTML**, YouTube is blocking requests or serving a consent/interstitial page to your IP/network. Retrying later or using a different network/IP usually resolves it.
