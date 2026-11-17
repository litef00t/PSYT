# PSYT

![drawing](Media/PSYT.png)

## PowerShell Module for Retrieving YouTube Transcripts

### Using the Module

```powershell
Install-Module -Name PSYT
```

### Example

Reqirements:

- [PSAI Module](https://github.com/dfinke/psai)
- [OpenAI API Key](https://help.openai.com/en/articles/4936850-where-do-i-find-my-openai-api-key)

In this example, we will retrieve the transcript of a YouTube video and then generate a summary of the main points and key takeaways from the transcript using the GPT-4o-mini model.

```powershell
# Source: https://youtu.be/OHQFObW6PXA
$transcriptParams = @{
    videoId            = 'OHQFObW6PXA'
    IncludeTitle       = $true
    IncludeDescription = $true
}

$transcript = Get-Transcript @transcriptParams

$summaryInput = @"
# Title:
$($transcript.title)

# Description:
$($transcript.description)

# Transcript:
$($transcript.transcript | Out-String)
"@

$summaryParams = @{
    Instructions = 'Write a concise summary of the with 3-5 bullet points that highlight the key points or takeaways from the video transcript, include the title and details from the description.'
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

The GitHub Actions workflow runs Pester 5 tests named `*.Tests.ps1` on pull requests and pushes to `main`. It stops if no tests are present or none pass.

After tests pass on a push to `main`, the workflow increments the patch version in `PSYT.psd1`, commits it back to `main`, and publishes to PowerShell Gallery. For example, `0.3.0` becomes `0.3.1`. The bot's version commit does not trigger another workflow run.

Add a repository Actions secret named `PSGALLERY_API_KEY` containing a Gallery API key with permission to publish PSYT. Repository rules must allow the workflow's `GITHUB_TOKEN` to push the version commit to `main`.

The version commit happens before publishing. If Gallery publishing fails, that version remains in Git. Re-running the old workflow stops because `main` has moved; the next push to `main` retries with the next patch version. If `main` changes while a run is testing, the older run stops and the newer run handles publishing.

### Notes / Troubleshooting

- The module fetches caption-track metadata via YouTube's Innertube player API (mirroring `youtube-transcript-api`) to avoid stale/blocked caption URLs.
- If you see errors like **HTTP 429**, **bot/recaptcha**, or **Expected transcript XML but received HTML**, YouTube is blocking requests from your IP/network. Retrying later or using a different network/IP usually resolves it.
