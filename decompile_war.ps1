param(
    [string]$InputDir = ".\wars"
)

# Check if input directory exists
if (-not (Test-Path $InputDir)) {
    Write-Error "Input directory not found: $InputDir"
    exit 1
}

# Find all WAR files in the directory
$WarFiles = Get-ChildItem -Path $InputDir -Filter "*.war" -File | Sort-Object Name

if ($WarFiles.Count -eq 0) {
    Write-Host "No WAR files found in: $InputDir" -ForegroundColor Yellow
    exit 0
}

Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  WAR Decompiler - Batch Processing" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "Found $($WarFiles.Count) WAR file(s) to process" -ForegroundColor Cyan
Write-Host ""

$script:SuccessCount = 0
$script:FailCount = 0
$script:CurrentDir = Get-Location
$script:ProjectsDir = Join-Path $script:CurrentDir "Projects of WARS"

# Create projects directory if it doesn't exist
if (-not (Test-Path $script:ProjectsDir)) {
    New-Item -ItemType Directory -Path $script:ProjectsDir -Force | Out-Null
    Write-Host "Created projects directory: $script:ProjectsDir" -ForegroundColor Cyan
} else {
    Write-Host "Using existing projects directory: $script:ProjectsDir" -ForegroundColor Cyan
}
Write-Host ""

function Process-SingleWar {
    param(
        [string]$WarFile
    )

    # Get absolute paths
    $WarFile = Resolve-Path $WarFile
    $WarName = [System.IO.Path]::GetFileNameWithoutExtension($WarFile)
    # Temporary extraction in current directory, source projects in projects directory
    $ExtractDir = Join-Path $script:CurrentDir "${WarName}_extracted"
    $ProjectDir = Join-Path $script:ProjectsDir "${WarName}_source"

    Write-Host "Extracting WAR file: $WarFile" -ForegroundColor Green
    Write-Host "Extract directory: $ExtractDir" -ForegroundColor Yellow
    Write-Host "Project directory: $ProjectDir" -ForegroundColor Yellow

    # Step 1: Extract WAR file (WAR files are just ZIP files)
    if (Test-Path $ExtractDir) {
        Write-Host "Removing existing extract directory..." -ForegroundColor Yellow
        Remove-Item $ExtractDir -Recurse -Force
    }

    Write-Host "Extracting WAR file..." -ForegroundColor Cyan
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($WarFile, $ExtractDir)
    } catch {
        Write-Error "Failed to extract WAR file: $($_.Exception.Message)"
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
    New-Item -ItemType Directory -Path "$ProjectDir\src\main\webapp" -Force | Out-Null
    New-Item -ItemType Directory -Path "$ProjectDir\lib" -Force | Out-Null

    # Step 3: Copy web resources
    $WebInfDir = Join-Path $ExtractDir "WEB-INF"
    if (Test-Path $WebInfDir) {
        Write-Host "Copying web.xml and web resources..." -ForegroundColor Cyan

        # Copy WEB-INF contents to webapp
        Copy-Item "$ExtractDir\*" "$ProjectDir\src\main\webapp\" -Recurse -Force

        # Copy JAR files to lib directory
        $LibDir = Join-Path $WebInfDir "lib"
        if (Test-Path $LibDir) {
            Copy-Item "$LibDir\*.jar" "$ProjectDir\lib\" -Force
            Write-Host "Copied JAR dependencies to lib directory" -ForegroundColor Green
        }
    }

    # Step 4: Find and decompile class files
    Write-Host "Searching for class files to decompile..." -ForegroundColor Cyan
    $ClassesDir = Join-Path $WebInfDir "classes"

    if (Test-Path $ClassesDir) {
        $ClassFiles = Get-ChildItem -Path $ClassesDir -Filter "*.class" -Recurse
        Write-Host "Found $($ClassFiles.Count) class files" -ForegroundColor Green

        # Check for Java decompilers
        $DecompilerFound = $false
        $DecompilerCommand = ""

        # Check for CFR decompiler
        if (Get-Command "java" -ErrorAction SilentlyContinue) {
            # Try to download CFR if not present
            $CfrPath = Join-Path $script:CurrentDir "cfr.jar"
            if (-not (Test-Path $CfrPath)) {
                Write-Host "Downloading CFR decompiler..." -ForegroundColor Yellow
                try {
                    Invoke-WebRequest -Uri "https://github.com/leibnitz27/cfr/releases/download/0.152/cfr-0.152.jar" -OutFile $CfrPath
                    $DecompilerFound = $true
                    $DecompilerCommand = "java -jar `"$CfrPath`""
                    Write-Host "CFR decompiler downloaded successfully" -ForegroundColor Green
                }
                catch {
                    Write-Warning "Failed to download CFR decompiler: $($_.Exception.Message)"
                }
            }
            else {
                $DecompilerFound = $true
                $DecompilerCommand = "java -jar `"$CfrPath`""
                Write-Host "Using existing CFR decompiler" -ForegroundColor Green
            }
        }
    
        if ($DecompilerFound) {
            Write-Host "Decompiling class files..." -ForegroundColor Cyan

            foreach ($ClassFile in $ClassFiles) {
                # Calculate relative path from classes directory
                $RelativePath = $ClassFile.FullName.Substring($ClassesDir.Length + 1)
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

                # Decompile the class file with UTF-8 encoding
                try {
                    $DecompileCmd = "$DecompilerCommand `"$($ClassFile.FullName)`" --outputdir `"$ProjectDir\src\main\java`" --outputencoding utf-8"
                    Invoke-Expression $DecompileCmd | Out-Null
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
            Copy-Item "$ClassesDir\*" "$ProjectDir\src\main\java\" -Recurse -Force
        }
    }
    else {
        Write-Warning "No classes directory found in WAR file"
    }

    # Step 5: Copy resources
    Write-Host "Copying resource files..." -ForegroundColor Cyan
    $ResourceDirs = @("META-INF", "config", "properties")
    foreach ($ResourceDir in $ResourceDirs) {
        $SourcePath = Join-Path $ClassesDir $ResourceDir
        if (Test-Path $SourcePath) {
            Copy-Item $SourcePath "$ProjectDir\src\main\resources\" -Recurse -Force
            Write-Host "Copied resources from: $ResourceDir" -ForegroundColor Gray
        }
    }

    # Step 6: Generate basic pom.xml for Maven project
    Write-Host "Generating pom.xml..." -ForegroundColor Cyan
    $PomContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
         http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>

    <groupId>com.example</groupId>
    <artifactId>$WarName</artifactId>
    <version>1.0.0</version>
    <packaging>war</packaging>

    <properties>
        <maven.compiler.source>8</maven.compiler.source>
        <maven.compiler.target>8</maven.compiler.target>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    </properties>

    <dependencies>
        <!-- Add dependencies based on JAR files found -->
        <dependency>
            <groupId>javax.servlet</groupId>
            <artifactId>javax.servlet-api</artifactId>
            <version>4.0.1</version>
            <scope>provided</scope>
        </dependency>
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
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-war-plugin</artifactId>
                <version>3.2.3</version>
                <configuration>
                    <warSourceDirectory>src/main/webapp</warSourceDirectory>
                </configuration>
            </plugin>
        </plugins>
    </build>
</project>
"@

    Set-Content -Path "$ProjectDir\pom.xml" -Value $PomContent

    # Step 7: Clean up temporary extraction directory
    Write-Host "Cleaning up temporary files..." -ForegroundColor Cyan
    if (Test-Path $ExtractDir) {
        Remove-Item $ExtractDir -Recurse -Force
        Write-Host "Removed temporary extraction directory" -ForegroundColor Green
    }

    Write-Host "Reverse engineering completed successfully!" -ForegroundColor Green
    Write-Host "Java project created at: $ProjectDir" -ForegroundColor Yellow
    Write-Host ""

    return $true
}

# Main loop - Process all WAR files
for ($i = 0; $i -lt $WarFiles.Count; $i++) {
    $warFile = $WarFiles[$i]
    $warSizeMB = [math]::Round($warFile.Length / 1MB, 2)

    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "Processing file $($i + 1) of $($WarFiles.Count): $($warFile.Name)" -ForegroundColor Magenta
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "Size: $warSizeMB MB" -ForegroundColor White
    Write-Host ""

    try {
        $result = Process-SingleWar -WarFile $warFile.FullName

        if ($result) {
            Write-Host "[SUCCESS] Completed: $($warFile.Name)" -ForegroundColor Green
            $script:SuccessCount++
        } else {
            Write-Host "[FAILED] Error processing: $($warFile.Name)" -ForegroundColor Red
            $script:FailCount++
        }
    } catch {
        Write-Host "[FAILED] Exception: $($warFile.Name)" -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        $script:FailCount++
    }

    Write-Host ""
}

# Final summary
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "  SUMMARY" -ForegroundColor Magenta
Write-Host "============================================" -ForegroundColor Magenta
Write-Host "Total files processed: $($WarFiles.Count)" -ForegroundColor White
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