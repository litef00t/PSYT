# V0.4.0

- Harden video ID/URL parsing, timedtext origin/redirect handling, XML DTD protection, and HTTP/playability error reporting (breaking: invalid inputs and request failures now throw instead of writing via `Write-Host`)
- Add `-OutputFormat Text` for plain-text transcript output, escape Markdown table cells, and return consistent arrays in `PSObject` mode
- Add per-function comment-based help, request timeouts, manifest metadata hygiene, and cross-platform offline Pester 5 + PSScriptAnalyzer CI checks
- Fix README and example scripts (`Examples/Gemini.ps1` and `Examples/get-transcript-gpt-4o-mini.ipynb`)

# V0.3.0

- Fix transcript fetch (Innertube caption tracks + robust XML handling)

# V0.2.0

- changed default output to `markdown`, can choose `psobject`

# V0.1.0

- FIX: Linux and MacOS compatibility

# v0.0.2

- Fix: HTML Encoding issue
  
# v0.0.1

- First release
  