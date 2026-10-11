param(
    [string]$Mod42Directory
)

$ErrorActionPreference = "Stop"

if (-not $Mod42Directory) {
    $Mod42Directory = Split-Path -Parent $PSScriptRoot
}
$mod42Directory = [System.IO.Path]::GetFullPath($Mod42Directory)
$playlistDirectory = Join-Path $mod42Directory "media\sound\TheRoadSoFarFM\SingleplayerPlaylist"
$generatedSoundDirectory = Join-Path $mod42Directory "media\sound\TheRoadSoFarFM\SingleplayerPlaylist_Generated"
$seedMarker = Join-Path $playlistDirectory ".trsf-defaults-copied"
$defaultSongsDirectory = Join-Path $mod42Directory "media\sound\TheRoadSoFarFM"
$soundOutputPath = Join-Path $mod42Directory "media\scripts\TheRoadSoFarFM_UserPlaylist_Sounds.txt"
$luaOutputDirectory = Join-Path $mod42Directory "media\lua\shared\TheRoadSoFarFM_Custom"
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

try {
    New-Item -ItemType Directory -Path $playlistDirectory -Force | Out-Null

    if (-not (Test-Path -LiteralPath $seedMarker)) {
        $defaultSongs = Get-ChildItem -LiteralPath $defaultSongsDirectory -File -Filter '*.ogg'
        foreach ($song in $defaultSongs) {
            $destination = Join-Path $playlistDirectory $song.Name
            if (-not (Test-Path -LiteralPath $destination)) {
                Copy-Item -LiteralPath $song.FullName -Destination $destination
            }
        }
        Write-Utf8FileWithoutBom -Path $seedMarker -Content "initialized"
        Write-Host "Se copiaron las canciones originales que aun no existian en la carpeta personalizada."
    }

    $inputFiles = Get-ChildItem -LiteralPath $playlistDirectory -File |
        Where-Object { $_.Extension -match '^\.(ogg|mp3)$' } |
        Sort-Object Name
    if (-not $inputFiles) {
        throw "No hay canciones en '$playlistDirectory'. Añade archivos MP3 u OGG y vuelve a ejecutar el generador."
    }

    New-Item -ItemType Directory -Path $generatedSoundDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $soundOutputPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $luaOutputPath) -Force | Out-Null
    Get-ChildItem -LiteralPath $generatedSoundDirectory -File -Filter 'TRSF_Custom_*' |
        Remove-Item -Force

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

        $soundName = "TRSF_Custom_$slug"
        $suffix = 2
        while ($usedIdentifiers.ContainsKey($soundName)) {
            $soundName = "TRSF_Custom_${slug}_$suffix"
            $suffix++
        }
        $usedIdentifiers[$soundName] = $true

        $generatedFileName = "$soundName$($inputFile.Extension.ToLowerInvariant())"
        Copy-Item -LiteralPath $inputFile.FullName -Destination (Join-Path $generatedSoundDirectory $generatedFileName) -Force
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
            file = media/sound/TheRoadSoFarFM/SingleplayerPlaylist_Generated/$generatedFileName,
            volume = 1.0,
        }
    }
"@)
    }

    $soundScript = "module Base`r`n{`r`n" + ($soundDefinitions -join "`r`n") + "`r`n}`r`n"
    $luaTracks = ($trackIdentifiers | ForEach-Object { '    "' + $_ + '",' }) -join "`r`n"
    $luaTitles = $trackTitles -join "`r`n"
    $luaPlaylist = @"
TheRoadSoFarFMCustomPlaylist = {
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
    Write-Host "Playlist singleplayer generada con $($trackIdentifiers.Count) canciones dentro del mod."
    Write-Host "Canciones: $playlistDirectory"
    Write-Host "Reinicia el juego para cargar los nuevos sonidos."
    Write-Host "Multiplayer conserva la playlist normal del mod."
}
catch {
    Write-Error $_
    exit 1
}
