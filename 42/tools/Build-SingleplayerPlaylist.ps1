param(
    [string]$Mod42Directory
)

$ErrorActionPreference = "Stop"

if (-not $Mod42Directory) {
    $Mod42Directory = Split-Path -Parent $PSScriptRoot
}
$mod42Directory = [System.IO.Path]::GetFullPath($Mod42Directory)
$radioDirectory = Join-Path $mod42Directory "media\sound\Radio"
$playlistDirectory = Join-Path $radioDirectory "UserTracks"
$soundOutputPath = Join-Path $mod42Directory "media\scripts\Radio_UserPlaylist_Sounds.txt"
$luaOutputDirectory = Join-Path $mod42Directory "media\lua\shared\TheRoadSoFarFM\Radio\Custom"
$luaOutputPath = Join-Path $luaOutputDirectory "Playlist.lua"

function Write-Utf8FileWithoutBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function ConvertTo-LuaString {
    param([string]$Value)

    return '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n') + '"'
}

function ConvertTo-AsciiTitle {
    param([string]$Value)

    $normalized = $Value.Normalize([System.Text.NormalizationForm]::FormD)
    $withoutDiacritics = [regex]::Replace($normalized, '\p{Mn}', '')
    return [regex]::Replace($withoutDiacritics, '[^\x00-\x7F]', '')
}

function Remove-LegacyGeneratedSounds {
    $legacyGeneratedSoundDirectory = Join-Path $mod42Directory "media\sound\Radio\SingleplayerPlaylist_Generated"
    if (Test-Path -LiteralPath $legacyGeneratedSoundDirectory) {
        Get-ChildItem -LiteralPath $legacyGeneratedSoundDirectory -File -Filter 'TRSF_Custom_*' |
            Remove-Item -Force
        if (-not (Get-ChildItem -LiteralPath $legacyGeneratedSoundDirectory -Force)) {
            Remove-Item -LiteralPath $legacyGeneratedSoundDirectory
        }
    }
}

try {
    New-Item -ItemType Directory -Path $playlistDirectory -Force | Out-Null

    $inputFiles = Get-ChildItem -LiteralPath $playlistDirectory -File |
        Where-Object { $_.Extension -match '^\.(ogg|mp3)$' } |
        Sort-Object Name
    if (-not $inputFiles) {
        foreach ($outputPath in @($soundOutputPath, $luaOutputPath)) {
            if (Test-Path -LiteralPath $outputPath) {
                Remove-Item -LiteralPath $outputPath -Force
            }
        }
        Remove-LegacyGeneratedSounds
        $luaOutputDirectoryIsEmpty = Test-Path -LiteralPath $luaOutputDirectory -PathType Container
        if ($luaOutputDirectoryIsEmpty) {
            $luaOutputDirectoryIsEmpty = -not (Get-ChildItem -LiteralPath $luaOutputDirectory -Force)
        }
        if ($luaOutputDirectoryIsEmpty) {
            Remove-Item -LiteralPath $luaOutputDirectory
        }

        Write-Host ""
        Write-Host "No MP3 or OGG files were found in '$playlistDirectory'."
        Write-Host "Generated User Tracks files were cleared; 100.2 MHz will not be registered."
        Write-Host "Add songs to the folder and run Load_My_Songs.cmd again when you are ready."
        return
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $soundOutputPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $luaOutputPath) -Force | Out-Null
    Remove-LegacyGeneratedSounds

    $soundDefinitions = [System.Collections.Generic.List[string]]::new()
    $trackIdentifiers = [System.Collections.Generic.List[string]]::new()
    $trackTitles = [System.Collections.Generic.List[string]]::new()
    $usedIdentifiers = @{}

    foreach ($inputFile in $inputFiles) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($inputFile.Name)
        $slug = [regex]::Replace($baseName, '[^A-Za-z0-9]+', '_').Trim('_')
        if (-not $slug) {
            $slug = "Song"
        }

        $soundName = "TRSF_UserTracks_$slug"
        $suffix = 2
        while ($usedIdentifiers.ContainsKey($soundName)) {
            $soundName = "TRSF_UserTracks_${slug}_$suffix"
            $suffix++
        }
        $usedIdentifiers[$soundName] = $true

        $trackIdentifiers.Add($soundName)
        $trackTitle = ConvertTo-AsciiTitle ([System.IO.Path]::GetFileNameWithoutExtension($inputFile.Name))
        $trackTitles.Add("    $soundName = " + (ConvertTo-LuaString $trackTitle) + ',')
        $soundDefinitions.Add(@"
    sound $soundName
    {
        category = Music,
        loop = false,
        is3D = false,
        clip
        {
            file = media/sound/Radio/UserTracks/$($inputFile.Name),
            volume = 1.0,
        }
    }
"@)
    }

    $soundScript = "module Base`r`n{`r`n" + ($soundDefinitions -join "`r`n") + "`r`n}`r`n"
    $luaTracks = ($trackIdentifiers | ForEach-Object { '    "' + $_ + '",' }) -join "`r`n"
    $luaTitles = $trackTitles -join "`r`n"
    $luaPlaylist = @"
TheRoadSoFarFMUserTracksConfig = {
    IsCustomPlaylist = true,
    NoCommercials = true,
    Tracks = {
$luaTracks
    },
    TrackTitles = {
$luaTitles
    },
}
"@

    Write-Utf8FileWithoutBom -Path $soundOutputPath -Content $soundScript
    Write-Utf8FileWithoutBom -Path $luaOutputPath -Content $luaPlaylist

    Write-Host ""
    Write-Host "User Tracks FM (100.2 MHz) was generated with $($trackIdentifiers.Count) songs."
    Write-Host "Songs folder: $playlistDirectory"
    Write-Host "Restart Project Zomboid to load the new sound definitions."
    Write-Host "Custom User Tracks are singleplayer-only; multiplayer keeps the default playlist."
}
catch {
    Write-Error $_
    exit 1
}
