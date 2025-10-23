param(
    [string]$InputDir = ".\tars",
    [string]$OutputDir = ".\jars"
)

# --- Color Codes for Logging ---
function Write-Info { param([string]$Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Write-Warning { param([string]$Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Error { param([string]$Message) Write-Host $Message -ForegroundColor Red }
function Write-Header { param([string]$Message) Write-Host $Message -ForegroundColor Magenta }
function Write-Data { param([string]$Message) Write-Host $Message -ForegroundColor White }

# --- Cleanup ---
$script:TempWorkDir = $null

function Initialize-TempWorkDir {
    $script:TempWorkDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "docker-process-$(Get-Random)")
}

function Cleanup-Temp {
    if ($script:TempWorkDir -and (Test-Path $script:TempWorkDir)) {
        Remove-Item -Path $script:TempWorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Core Functions ---

function Extract-TarFile {
    param(
        [string]$TarPath,
        [string]$Destination
    )

    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
        $result = & tar.exe -xf "$TarPath" -C "$Destination" 2>&1
        return $LASTEXITCODE -eq 0
    } else {
        throw "tar.exe not found. Please ensure you're running Windows 10 or later."
    }
}

function Extract-DockerLayers {
    param(
        [string]$ExtractPath
    )

    $layerTars = Get-ChildItem -Path $ExtractPath -Recurse -Filter "layer.tar" -File -ErrorAction SilentlyContinue

    if ($layerTars.Count -eq 0) {
        return $false
    }

    Write-Success "  Found $($layerTars.Count) Docker layer(s) (Docker save format)"

    foreach ($layerTar in $layerTars) {
        $layerExtractDir = Join-Path (Split-Path $layerTar.FullName -Parent) "extracted"
        Extract-TarFile -TarPath $layerTar.FullName -Destination $layerExtractDir | Out-Null
    }

    return $true
}

function Extract-OciLayers {
    param(
        [string]$ExtractPath
    )

    $blobsPath = Join-Path $ExtractPath "blobs\sha256"
    if (-not (Test-Path $blobsPath)) {
        return $false
    }

    $blobs = Get-ChildItem -Path $blobsPath -File -ErrorAction SilentlyContinue
    if ($blobs.Count -eq 0) {
        return $false
    }

    Write-Success "  Found $($blobs.Count) blob(s) (OCI format)"
    $extractedCount = 0

    foreach ($blob in $blobs) {
        $blobSize = $blob.Length
        if ($blobSize -lt 1048576) { continue }  # Skip files smaller than 1 MB

        $blobExtractDir = Join-Path (Split-Path $blob.FullName -Parent) "$($blob.Name)_extracted"
        New-Item -ItemType Directory -Path $blobExtractDir -Force -ErrorAction SilentlyContinue | Out-Null

        # Try to extract as gzipped tar first, then as plain tar
        try {
            # Try gzipped tar
            $tempFile = [System.IO.Path]::GetTempFileName()
            & tar.exe -xzf "$($blob.FullName)" -C "$blobExtractDir" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $extractedCount++
                continue
            }
        } catch { }

        try {
            # Try plain tar
            & tar.exe -xf "$($blob.FullName)" -C "$blobExtractDir" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $extractedCount++
            }
        } catch { }
    }

    return $extractedCount -gt 0
}

function Get-MainJarFile {
    param(
        [string[]]$JarFilesList
    )

    if ($JarFilesList.Count -eq 0) {
        Write-Error "  Error: No JAR files provided to analyze."
        return $null
    }

    # Filter out library JARs and common framework JARs
    $appJars = @()
    $excludedPatterns = @(
        '\\lib\\', '\\libs\\', '\\dependencies\\',  # Library directories
        '^spring-', '^commons-', '^jackson-', '^lombok-', '^slf4j-', '^logback-',  # Common frameworks
        '^charsets\.jar$', '^jce\.jar$', '^jsse\.jar$', '^management-agent\.jar$',
        '^resources\.jar$', '^rt\.jar$', '^cldrdata\.jar$', '^dnsns\.jar$',
        '^jaccess\.jar$', '^localedata\.jar$', '^nashorn\.jar$', '^sunec\.jar$',
        '^sunjce_provider\.jar$', '^sunpkcs11\.jar$', '^zipfs\.jar$'
    )

    foreach ($jar in $JarFilesList) {
        $jarName = Split-Path $jar -Leaf
        $skip = $false

        # Check if JAR is in a library directory
        if ($jar -match '\\(lib|libs|dependencies)\\') {
            continue
        }

        # Check if JAR matches excluded patterns
        foreach ($pattern in $excludedPatterns) {
            if ($jarName -match $pattern) {
                $skip = $true
                break
            }
        }

        if (-not $skip) {
            $appJars += $jar
        }
    }

    if ($appJars.Count -eq 0) {
        Write-Warning "  No specific application JAR found, searching all JARs."
        $appJars = $JarFilesList
    }

    # Find the largest JAR file
    $mainJar = $null
    $maxSize = 0

    foreach ($jar in $appJars) {
        $size = (Get-Item $jar).Length
        if ($size -gt $maxSize) {
            $maxSize = $size
            $mainJar = $jar
        }
    }

    if (-not $mainJar) {
        Write-Error "  Could not determine the main JAR file."
        return $null
    }

    return $mainJar
}

function Get-ImageTagFromTar {
    param(
        [string]$TarPath
    )

    try {
        # Extract manifest.json from tar and parse with ConvertFrom-Json
        $manifestContent = & tar.exe -xOf "$TarPath" manifest.json 2>$null
        if ($LASTEXITCODE -eq 0 -and $manifestContent) {
            $manifest = $manifestContent | ConvertFrom-Json
            $repoTag = $manifest[0].RepoTags[0]
            return $repoTag
        }
    } catch {
        return $null
    }
    return $null
}

function Extract-JarFromTar {
    param(
        [string]$TarFile
    )

    $tempExtractDir = Join-Path $script:TempWorkDir "extract"

    Write-Info "  Extracting main TAR file..."
    if (-not (Extract-TarFile -TarPath $TarFile -Destination $tempExtractDir)) {
        return $null
    }

    $dockerLayersFound = Extract-DockerLayers -ExtractPath $tempExtractDir
    $ociLayersFound = Extract-OciLayers -ExtractPath $tempExtractDir

    if (-not $dockerLayersFound -and -not $ociLayersFound) {
        Write-Warning "  No Docker/OCI layers found. Searching entire archive for JARs."
    }

    $jarFiles = Get-ChildItem -Path $tempExtractDir -Recurse -Filter "*.jar" -File -ErrorAction SilentlyContinue

    if ($jarFiles.Count -eq 0) {
        Write-Error "  No JAR files found in the TAR archive."
        Write-Warning "  This may not be a Java application image. Skipping..."
        return $null
    }

    Write-Success "  Found $($jarFiles.Count) total JAR file(s)."

    $mainJar = Get-MainJarFile -JarFilesList $jarFiles.FullName

    if (-not $mainJar) {
        return $null
    }

    $jarName = Split-Path $mainJar -Leaf
    $jarSizeMB = [math]::Round((Get-Item $mainJar).Length / 1MB, 2)
    Write-Warning "  Identified main JAR: $jarName ($jarSizeMB MB)"

    $finalJarPath = Join-Path $script:TempWorkDir $jarName
    Copy-Item -Path $mainJar -Destination $finalJarPath -Force

    # Clean up extraction directory
    Remove-Item -Path $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue

    return $finalJarPath
}

function Process-SingleTar {
    param(
        [string]$TarFile,
        [string]$TarName
    )

    # Clean the temporary directory
    Get-ChildItem -Path $script:TempWorkDir -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    $extractedJarPath = Extract-JarFromTar -TarFile $TarFile

    if (-not $extractedJarPath) {
        return $false
    }

    # Get the original image tag
    $originalTag = Get-ImageTagFromTar -TarPath $TarFile

    $outputJarName = $null
    if ($originalTag -and $originalTag -ne "null" -and $originalTag -ne "") {
        Write-Info "  Found original image tag: $originalTag"
        # Extract the tag part and use it for naming
        $tagPart = ($originalTag -split ':')[-1]
        $imagePart = ($originalTag -split ':')[0] -replace '/', '-'
        $outputJarName = "$imagePart-$tagPart.jar"
    } else {
        Write-Warning "  Could not find original tag. Deriving name from filename."
        $tarBaseName = [System.IO.Path]::GetFileNameWithoutExtension($TarName)
        $outputJarName = "$tarBaseName.jar"
    }

    $outputJarPath = Join-Path $OutputDir $outputJarName
    Copy-Item -Path $extractedJarPath -Destination $outputJarPath -Force

    $outputSizeMB = [math]::Round((Get-Item $outputJarPath).Length / 1MB, 2)
    Write-Success "  Created: $(Split-Path $outputJarPath -Leaf) ($outputSizeMB MB)"

    return $true
}

function Main {
    Write-Header "============================================"
    Write-Header "  JAR Extractor"
    Write-Header "============================================"
    Write-Host ""

    # Check for tar.exe
    if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
        Write-Error "FATAL: tar.exe is not available. Please use Windows 10 or later."
        exit 1
    }

    Write-Data "Tar: $(& tar.exe --version | Select-Object -First 1)"
    Write-Info "Input Directory: $InputDir"
    Write-Info "Output Directory: $OutputDir"
    Write-Host ""

    if (-not (Test-Path $InputDir)) {
        Write-Error "Input directory not found: $InputDir"
        exit 1
    }

    # Create output directory
    if (Test-Path $OutputDir) {
        Write-Warning "Output directory exists: $OutputDir"
    } else {
        Write-Info "Creating output directory: $OutputDir"
    }
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    # Initialize temp work directory
    Initialize-TempWorkDir

    # Find all TAR files
    $tarFiles = Get-ChildItem -Path $InputDir -Filter "*.tar" -File -ErrorAction SilentlyContinue | Sort-Object Name

    if ($tarFiles.Count -eq 0) {
        Write-Warning "No .tar files found in $InputDir"
        Cleanup-Temp
        exit 0
    }

    Write-Info "Found $($tarFiles.Count) TAR file(s) to process."
    Write-Host ""

    $successCount = 0
    $failCount = 0

    for ($i = 0; $i -lt $tarFiles.Count; $i++) {
        $tarFile = $tarFiles[$i]
        $tarName = $tarFile.Name
        $tarSizeMB = [math]::Round($tarFile.Length / 1MB, 2)

        Write-Header "========================================"
        Write-Header "Processing file $($i + 1) of $($tarFiles.Count): $tarName"
        Write-Header "========================================"
        Write-Data "Input size: $tarSizeMB MB"

        try {
            $result = Process-SingleTar -TarFile $tarFile.FullName -TarName $tarName

            if ($result) {
                Write-Success "SUCCESS!"
                $successCount++
            } else {
                Write-Error "ERROR: Failed to process $tarName"
                $failCount++
            }
        } catch {
            Write-Error "ERROR: Failed to process $tarName"
            Write-Error "  Exception: $($_.Exception.Message)"
            $failCount++
        }

        Write-Host ""
    }

    Write-Header "============================================"
    Write-Header "  SUMMARY"
    Write-Header "============================================"
    Write-Data "Total files processed: $($tarFiles.Count)"
    Write-Success "Successful: $successCount"

    if ($failCount -gt 0) {
        Write-Error "Failed: $failCount"
    } else {
        Write-Data "Failed: $failCount"
    }

    Write-Info "Output directory: $OutputDir"
    Write-Host ""
    Write-Success "DONE!"

    # Cleanup
    Cleanup-Temp
}

# Run main function
try {
    Main
} catch {
    Write-Error "Unhandled error: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
    Cleanup-Temp
    exit 1
}
