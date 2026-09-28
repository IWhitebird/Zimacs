# Installs the latest Zimacs release under %LOCALAPPDATA%, adds it to PATH and
# puts a shortcut in the Start Menu so it appears in the app list and search.
#
#   irm https://raw.githubusercontent.com/IWhitebird/Zimacs/master/scripts/install.ps1 | iex

$ErrorActionPreference = "Stop"
# Windows PowerShell redraws the download progress bar so often that it
# slows the download itself down many times over.
$ProgressPreference = "SilentlyContinue"

$repo = "IWhitebird/Zimacs"
$root = Join-Path $env:LOCALAPPDATA "Programs\Zimacs"

# Windows will not replace a running exe, so say so before downloading.
$running = Get-Process -Name Zimacs -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$root\*" }
if ($running) { throw "Zimacs is running. Close it, then run this again." }

Write-Host "Looking up the latest release"
$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest"
$tag = $release.tag_name
if (-not $tag) { throw "could not work out the latest release" }

$name = "zimacs-$tag-windows-x86_64"
$url = "https://github.com/$repo/releases/download/$tag/$name.zip"

$tmp = Join-Path $env:TEMP "zimacs-install-$tag"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$zip = Join-Path $tmp "$name.zip"

try {
    Write-Host "Downloading Zimacs $tag"
    Invoke-WebRequest $url -OutFile $zip -UseBasicParsing

    # Verify against the checksum published next to the zip. This catches a
    # truncated download; it is not a signature and does not prove authorship.
    # GitHub serves the .sha256 as application/octet-stream, so .Content on the
    # response is a byte array, not text, and splitting it compares the hash
    # against the first byte's number. Saving it and reading it back as text
    # behaves the same on Windows PowerShell 5.1 and PowerShell 7.
    $sumFile = Join-Path $tmp "$name.zip.sha256"
    $haveSum = $true
    try {
        Invoke-WebRequest "$url.sha256" -OutFile $sumFile -UseBasicParsing
    } catch {
        $haveSum = $false
        Write-Host "No checksum published, skipping verification"
    }
    if ($haveSum) {
        $want = ((Get-Content $sumFile -Raw).Trim() -split '\s+')[0]
        $got = (Get-FileHash $zip -Algorithm SHA256).Hash
        if ($got -ne $want) {
            throw "checksum did not match, refusing to install (expected $want, got $got)"
        }
        Write-Host "Checksum verified"
    }

    Expand-Archive $zip -DestinationPath $tmp -Force
    $src = Join-Path $tmp $name

    # Replace any previous install rather than merging into it.
    if (Test-Path $root) { Remove-Item $root -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Copy-Item (Join-Path $src "*") $root -Recurse -Force

    $exe = Join-Path $root "Zimacs.exe"
    if (-not (Test-Path $exe)) { throw "the archive did not contain Zimacs.exe" }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# Start Menu entry. This is what puts Zimacs in the app list and in search.
$menu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path $menu "Zimacs.lnk"))
$link.TargetPath = $exe
$link.WorkingDirectory = $root
$link.IconLocation = $exe
$link.Description = "A small, fast text editor written in Zig"
$link.Save()

# PATH, for this user only, so no administrator rights are needed.
$path = [Environment]::GetEnvironmentVariable("Path", "User")
if ($path -notlike "*$root*") {
    [Environment]::SetEnvironmentVariable("Path", "$path;$root", "User")
    Write-Host "Added $root to your PATH. Open a new terminal to pick it up."
}

Write-Host ""
Write-Host "Zimacs $tag is installed to $root"
Write-Host "It is in the Start Menu, and 'Zimacs' works in a new terminal."
Write-Host ""
Write-Host "To remove it:"
Write-Host "  Remove-Item '$root' -Recurse -Force"
Write-Host "  Remove-Item '$menu\Zimacs.lnk'"
