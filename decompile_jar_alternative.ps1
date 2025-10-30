param(
    [string]$InputDir = ".\jars"
)

if (-not (Test-Path $InputDir)) {
    Write-Error "Input directory not found: $InputDir"
    exit 1
}

$JarFiles = Get-ChildItem -Path $InputDir -Filter "*.jar" -File | Sort-Object Name

if ($JarFiles.Count -eq 0) {
    Write-Host "No JAR files found in: $InputDir" -ForegroundColor Yellow
    exit 0
}

Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  JAR Decompiler - Alternative (Procyon)" -ForegroundColor Magenta
Write-Host "  For Standard Java Library JARs" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "Found $($JarFiles.Count) JAR file(s) to process" -ForegroundColor Cyan
Write-Host ""

$script:SuccessCount = 0
$script:FailCount = 0
$script:CurrentDir = Get-Location
$script:ProjectsDir = Join-Path $script:CurrentDir "Projects of JARS"

if (-not (Test-Path $script:ProjectsDir)) {
    New-Item -ItemType Directory -Path $script:ProjectsDir -Force | Out-Null
    Write-Host "Created projects directory: $script:ProjectsDir" -ForegroundColor Cyan
} else {
    Write-Host "Using existing projects directory: $script:ProjectsDir" -ForegroundColor Cyan
}
Write-Host ""

function Process-SingleJar {
    param(
        [string]$JarFile
    )

    # Get absolute paths
    $JarFile = Resolve-Path $JarFile
    $JarName = [System.IO.Path]::GetFileNameWithoutExtension($JarFile)
    # Temporary extraction in current directory, source projects in projects directory
    $ExtractDir = Join-Path $script:CurrentDir "${JarName}_extracted"
    $ProjectDir = Join-Path $script:ProjectsDir "${JarName}"

    Write-Host "Extracting JAR file: $JarFile" -ForegroundColor Green
    Write-Host "Extract directory: $ExtractDir" -ForegroundColor Yellow
    Write-Host "Project directory: $ProjectDir" -ForegroundColor Yellow

    # Step 1: Extract JAR file (JAR files are just ZIP files)
    if (Test-Path $ExtractDir) {
        Write-Host "Removing existing extract directory..." -ForegroundColor Yellow
        Remove-Item $ExtractDir -Recurse -Force
    }

    Write-Host "Extracting JAR file..." -ForegroundColor Cyan
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($JarFile, $ExtractDir)
    } catch {
        Write-Error "Failed to extract JAR file: $($_.Exception.Message)"
        return $false
    }

    # Step 2: Create Java project structure
    if (Test-Path $ProjectDir) {
        Write-Host "Removing existing project directory..." -ForegroundColor Yellow
        Remove-Item $ProjectDir -Recurse -Force
    }

    Write-Host "Creating Java project structure..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
    New-Item -ItemType Directory -Path "$ProjectDir\src\main\java" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ProjectDir\src\main\resources" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ProjectDir\lib" -Force | Out-Null

    # Step 3: Find and decompile class files (in root structure, not BOOT-INF)
    Write-Host "Searching for class files to decompile..." -ForegroundColor Cyan

    # Find all class files in the extracted directory (excluding inner classes for now)
    $ClassFiles = Get-ChildItem -Path $ExtractDir -Filter "*.class" -Recurse | Where-Object {
        # Exclude META-INF directory and inner classes (containing $)
        $_.FullName -notlike "*\META-INF\*" -and $_.Name -notlike "*`$*.class"
    }

    Write-Host "Found $($ClassFiles.Count) class files" -ForegroundColor Green

    # Check for Java and Procyon decompiler
    $DecompilerFound = $false
    $DecompilerCommand = ""

    if (Get-Command "java" -ErrorAction SilentlyContinue) {
        # Try to download Procyon if not present
        $ProcyonPath = Join-Path $script:CurrentDir "procyon-decompiler.jar"
        if (-not (Test-Path $ProcyonPath)) {
            Write-Host "Downloading Procyon decompiler..." -ForegroundColor Yellow
            try {
                Invoke-WebRequest -Uri "https://github.com/mstrobel/procyon/releases/download/v0.6.0/procyon-decompiler-0.6.0.jar" -OutFile $ProcyonPath
                $DecompilerFound = $true
                $DecompilerCommand = "java -jar `"$ProcyonPath`""
                Write-Host "Procyon decompiler downloaded successfully" -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to download Procyon decompiler: $($_.Exception.Message)"
            }
        }
        else {
            $DecompilerFound = $true
            $DecompilerCommand = "java -jar `"$ProcyonPath`""
            Write-Host "Using existing Procyon decompiler" -ForegroundColor Green
        }
    }

    if ($DecompilerFound) {
        Write-Host "Decompiling class files with Procyon..." -ForegroundColor Cyan

        foreach ($ClassFile in $ClassFiles) {
            # Calculate relative path from extraction directory
            $RelativePath = $ClassFile.FullName.Substring($ExtractDir.Length + 1)
            $PackagePath = Split-Path $RelativePath -Parent
            $ClassName = [System.IO.Path]::GetFileNameWithoutExtension($ClassFile.Name)

            # Create package directory structure
            if ($PackagePath) {
                $JavaPackageDir = Join-Path "$ProjectDir\src\main\java" $PackagePath
                New-Item -ItemType Directory -Path $JavaPackageDir -Force | Out-Null
                $OutputFile = Join-Path $JavaPackageDir "$ClassName.java"
            }
            else {
                $OutputFile = Join-Path "$ProjectDir\src\main\java" "$ClassName.java"
            }

            # Decompile the class file
            try {
                # Procyon outputs to stdout by default, we'll save it to a file
                $DecompileCmd = "$DecompilerCommand `"$($ClassFile.FullName)`""
                $DecompiledCode = Invoke-Expression $DecompileCmd 2>&1

                # Save to file with UTF-8 encoding
                Set-Content -Path $OutputFile -Value $DecompiledCode -Encoding UTF8
                Write-Host "Decompiled: $RelativePath" -ForegroundColor Gray
            }
            catch {
                Write-Warning "Failed to decompile $($ClassFile.Name): $($_.Exception.Message)"
            }
        }

        # Also decompile inner classes
        $InnerClassFiles = Get-ChildItem -Path $ExtractDir -Filter "*`$*.class" -Recurse | Where-Object {
            $_.FullName -notlike "*\META-INF\*"
        }

        Write-Host "Found $($InnerClassFiles.Count) inner class files" -ForegroundColor Green

        foreach ($ClassFile in $InnerClassFiles) {
            # Calculate relative path from extraction directory
            $RelativePath = $ClassFile.FullName.Substring($ExtractDir.Length + 1)
            $PackagePath = Split-Path $RelativePath -Parent
            $ClassName = [System.IO.Path]::GetFileNameWithoutExtension($ClassFile.Name)

            # Create package directory structure
            if ($PackagePath) {
                $JavaPackageDir = Join-Path "$ProjectDir\src\main\java" $PackagePath
                New-Item -ItemType Directory -Path $JavaPackageDir -Force | Out-Null
                $OutputFile = Join-Path $JavaPackageDir "$ClassName.java"
            }
            else {
                $OutputFile = Join-Path "$ProjectDir\src\main\java" "$ClassName.java"
            }

            # Decompile the class file
            try {
                $DecompileCmd = "$DecompilerCommand `"$($ClassFile.FullName)`""
                $DecompiledCode = Invoke-Expression $DecompileCmd 2>&1

                # Save to file with UTF-8 encoding
                Set-Content -Path $OutputFile -Value $DecompiledCode -Encoding UTF8
                Write-Host "Decompiled: $RelativePath" -ForegroundColor Gray
            }
            catch {
                Write-Warning "Failed to decompile $($ClassFile.Name): $($_.Exception.Message)"
            }
        }

        Write-Host "Decompilation completed!" -ForegroundColor Green
    }
    else {
        Write-Warning "No Java decompiler found. Class files copied as-is."
        # Copy class files to maintain structure
        $ClassFiles = Get-ChildItem -Path $ExtractDir -Filter "*.class" -Recurse | Where-Object {
            $_.FullName -notlike "*\META-INF\*"
        }
        foreach ($ClassFile in $ClassFiles) {
            $RelativePath = $ClassFile.FullName.Substring($ExtractDir.Length + 1)
            $DestPath = Join-Path "$ProjectDir\src\main\java" $RelativePath
            $DestDir = Split-Path $DestPath -Parent
            if (-not (Test-Path $DestDir)) {
                New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
            }
            Copy-Item $ClassFile.FullName $DestPath -Force
        }
    }

    # Step 4: Copy resources (properties files, etc.)
    Write-Host "Copying resource files..." -ForegroundColor Cyan
    $ResourceFiles = Get-ChildItem -Path $ExtractDir -Include "*.properties", "*.xml", "*.yml", "*.yaml" -Recurse | Where-Object {
        $_.FullName -notlike "*\META-INF\maven\*"
    }

    foreach ($ResourceFile in $ResourceFiles) {
        # Calculate relative path from extraction directory
        $RelativePath = $ResourceFile.FullName.Substring($ExtractDir.Length + 1)
        $DestPath = Join-Path "$ProjectDir\src\main\resources" $RelativePath

        # Create parent directory if needed
        $DestDir = Split-Path $DestPath -Parent
        if (-not (Test-Path $DestDir)) {
            New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
        }

        # Copy the file
        Copy-Item $ResourceFile.FullName $DestPath -Force
        Write-Host "Copied resource: $RelativePath" -ForegroundColor Gray
    }

    if ($ResourceFiles.Count -gt 0) {
        Write-Host "Copied $($ResourceFiles.Count) resource file(s)" -ForegroundColor Green
    }

    # Step 5: Copy META-INF (excluding Maven metadata)
    $MetaInfDir = Join-Path $ExtractDir "META-INF"
    if (Test-Path $MetaInfDir) {
        Write-Host "Copying META-INF directory..." -ForegroundColor Cyan

        # Create META-INF directory in resources
        $MetaInfDestDir = Join-Path "$ProjectDir\src\main\resources" "META-INF"
        if (-not (Test-Path $MetaInfDestDir)) {
            New-Item -ItemType Directory -Path $MetaInfDestDir -Force | Out-Null
        }

        $MetaInfItems = Get-ChildItem -Path $MetaInfDir | Where-Object {
            $_.Name -ne "maven"
        }

        foreach ($Item in $MetaInfItems) {
            $DestPath = Join-Path $MetaInfDestDir $Item.Name
            Copy-Item $Item.FullName $DestPath -Recurse -Force
        }
        Write-Host "Copied META-INF resources" -ForegroundColor Green
    }

    # Step 6: Use original pom.xml or generate basic one
    Write-Host "Looking for original pom.xml..." -ForegroundColor Cyan

    # Search for pom.xml in META-INF/maven directory
    $MavenMetaDir = Join-Path $ExtractDir "META-INF\maven"
    $OriginalPom = $null

    if (Test-Path $MavenMetaDir) {
        $OriginalPom = Get-ChildItem -Path $MavenMetaDir -Filter "pom.xml" -Recurse -File | Select-Object -First 1
    }

    if ($OriginalPom) {
        Write-Host "Found original pom.xml at: $($OriginalPom.FullName)" -ForegroundColor Green
        Copy-Item $OriginalPom.FullName "$ProjectDir\pom.xml" -Force
        Write-Host "Using original pom.xml" -ForegroundColor Green
    } else {
        Write-Host "No original pom.xml found, generating basic pom.xml..." -ForegroundColor Cyan
        $PomContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
         http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <groupId>com.decompiled</groupId>
    <artifactId>$JarName</artifactId>
    <version>1.0.0</version>
    <packaging>jar</packaging>

    <properties>
        <maven.compiler.source>8</maven.compiler.source>
        <maven.compiler.target>8</maven.compiler.target>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    </properties>

    <dependencies>
        <!-- Add dependencies as needed -->
    </dependencies>

    <build>
        <plugins>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-compiler-plugin</artifactId>
                <version>3.8.1</version>
                <configuration>
                    <source>8</source>
                    <target>8</target>
                </configuration>
            </plugin>
        </plugins>
    </build>
</project>
"@

        Set-Content -Path "$ProjectDir\pom.xml" -Value $PomContent
        Write-Host "Generated basic pom.xml" -ForegroundColor Green
    }

    # Step 7: Copy any JAR dependencies if found
    $JarDeps = Get-ChildItem -Path $ExtractDir -Filter "*.jar" -Recurse
    if ($JarDeps.Count -gt 0) {
        Write-Host "Found $($JarDeps.Count) JAR dependencies" -ForegroundColor Cyan
        foreach ($JarDep in $JarDeps) {
            Copy-Item $JarDep.FullName "$ProjectDir\lib\" -Force
            Write-Host "Copied: $($JarDep.Name)" -ForegroundColor Gray
        }
    }

    # Step 8: Clean up temporary extraction directory
    Write-Host "Cleaning up temporary files..." -ForegroundColor Cyan
    if (Test-Path $ExtractDir) {
        Remove-Item $ExtractDir -Recurse -Force
        Write-Host "Removed temporary extraction directory" -ForegroundColor Green
    }

    Write-Host "Decompilation completed successfully!" -ForegroundColor Green
    Write-Host "Java project created at: $ProjectDir" -ForegroundColor Yellow
    Write-Host ""

    return $true
}

# Main loop - Process all JAR files
for ($i = 0; $i -lt $JarFiles.Count; $i++) {
    $jarFile = $JarFiles[$i]
    $jarSizeMB = [math]::Round($jarFile.Length / 1MB, 2)

    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "Processing file $($i + 1) of $($JarFiles.Count): $($jarFile.Name)" -ForegroundColor Magenta
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "Size: $jarSizeMB MB" -ForegroundColor White
    Write-Host ""

    try {
        $result = Process-SingleJar -JarFile $jarFile.FullName

        if ($result) {
            Write-Host "[SUCCESS] Completed: $($jarFile.Name)" -ForegroundColor Green
            $script:SuccessCount++
        } else {
            Write-Host "[FAILED] Error processing: $($jarFile.Name)" -ForegroundColor Red
            $script:FailCount++
        }
    } catch {
        Write-Host "[FAILED] Exception: $($jarFile.Name)" -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        $script:FailCount++
    }

    Write-Host ""
}

# Final summary
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  SUMMARY" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "Total files processed: $($JarFiles.Count)" -ForegroundColor White
Write-Host "Successful: $script:SuccessCount" -ForegroundColor Green

if ($script:FailCount -gt 0) {
    Write-Host "Failed: $script:FailCount" -ForegroundColor Red
} else {
    Write-Host "Failed: $script:FailCount" -ForegroundColor White
}

Write-Host ""
Write-Host "Projects directory: $script:ProjectsDir" -ForegroundColor Yellow
Write-Host ""
Write-Host "DONE!" -ForegroundColor Green
