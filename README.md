# WhereIsTheSourceCode

A powerful toolkit for reverse engineering and decompiling Java applications from JAR files, WAR files, and Docker images. Extract and analyze Java source code from compiled bytecode with ease.

## Overview

WhereIsTheSourceCode provides a comprehensive suite of PowerShell scripts designed to:
- Extract and decompile JAR files to readable Java source code
- Convert WAR files into structured Maven projects
- Extract JAR files from Docker TAR archives (both Docker and OCI formats)
- Automatically create proper Maven project structures with dependencies

Perfect for developers who need to analyze legacy code, recover lost source code, or understand third-party Java applications.

## Features

- **Batch Processing**: Process multiple files at once with comprehensive progress reporting
- **Multiple Input Formats**: Supports JAR, WAR, and Docker TAR formats
- **CFR Decompiler Integration**: Uses the industry-standard CFR decompiler for accurate decompilation
- **Maven Project Generation**: Automatically creates proper Maven project structures with pom.xml
- **Smart JAR Detection**: Intelligently identifies main application JARs in Docker images
- **UTF-8 Encoding Support**: Ensures proper handling of international characters
- **Detailed Logging**: Color-coded progress and status messages

## Prerequisites

- **Windows 10 or later** (for tar.exe support)
- **Java Runtime Environment (JRE)** - Required to run the CFR decompiler
- **PowerShell 5.1 or later**

## Installation

1. Clone or download this repository:
```bash
git clone <repository-url>
cd WhereIsTheSourceCode
```

2. The CFR decompiler (cfr.jar) is included, or will be automatically downloaded when needed.

## Usage

### 1. Decompiling JAR Files

Place your JAR files in a directory (default: `.\jars`) and run:

```powershell
.\decompile_jar.ps1
```

Or specify a custom input directory:

```powershell
.\decompile_jar.ps1 -InputDir "C:\path\to\jars"
```

**Output**: Decompiled Java projects will be created in `.\Projects of JARS\` with the structure:
```
project-name_source/
├── src/
│   ├── main/
│   │   ├── java/          # Decompiled .java source files
│   │   ├── resources/     # Configuration and resource files
│   │   └── webapp/        # Web resources (if applicable)
├── lib/                   # JAR dependencies
└── pom.xml               # Maven project file
```

### 2. Decompiling WAR Files

Place your WAR files in a directory (default: `.\wars`) and run:

```powershell
.\decompile_war.ps1
```

Or specify a custom input directory:

```powershell
.\decompile_war.ps1 -InputDir "C:\path\to\wars"
```

**Output**: Decompiled Java projects will be created in `.\Projects of WARS\`

### 3. Extracting JARs from Docker Images

First, place the TAR files in a directory (default: `.\tars`) and run:

```powershell
.\Extract-JAR-From-TAR.ps1
```

Or specify custom directories:

```powershell
.\Extract-JAR-From-TAR.ps1 -InputDir "C:\path\to\tars" -OutputDir "C:\path\to\output"
```

**Output**: Extracted JAR files will be saved to `.\jars\` (or your specified OutputDir)

**Supported Formats**:
- Docker save format (with layer.tar files)
- OCI image format (with blobs)

## Script Parameters

### decompile_jar.ps1
| Parameter | Default | Description |
|-----------|---------|-------------|
| `-InputDir` | `.\jars` | Directory containing JAR files to decompile |

### decompile_war.ps1
| Parameter | Default | Description |
|-----------|---------|-------------|
| `-InputDir` | `.\wars` | Directory containing WAR files to decompile |

### Extract-JAR-From-TAR.ps1
| Parameter | Default | Description |
|-----------|---------|-------------|
| `-InputDir` | `.\tars` | Directory containing Docker TAR files |
| `-OutputDir` | `.\jars` | Directory for extracted JAR files |

## How It Works

### JAR/WAR Decompilation Process

1. **Extraction**: The script extracts the archive (JAR/WAR files are ZIP archives)
2. **Class File Discovery**: Locates all .class files in the BOOT-INF/classes or WEB-INF/classes directory
3. **Decompilation**: Uses CFR decompiler to convert bytecode to Java source
4. **Project Structure Creation**: Creates a standard Maven project layout
5. **Resource Copying**: Copies web resources, configuration files, and dependencies
6. **pom.xml Generation**: Creates a basic Maven configuration file
7. **Cleanup**: Removes temporary extraction files

### Docker TAR Processing

1. **Layer Detection**: Identifies Docker layers or OCI blobs
2. **Layer Extraction**: Extracts all layers from the image
3. **JAR Identification**: Scans for JAR files and identifies the main application JAR
4. **Smart Filtering**: Excludes common framework and library JARs
5. **Tag Preservation**: Maintains original Docker image tags in output filenames
6. **Extraction**: Copies the identified JAR to the output directory

## File Structure

```
WhereIsTheSourceCode/
├── cfr.jar                      # CFR decompiler (auto-downloaded if missing)
├── decompile_jar.ps1           # JAR decompilation script
├── decompile_war.ps1           # WAR decompilation script
├── Extract-JAR-From-TAR.ps1    # Docker TAR extraction script
├── Projects of JARS/           # Output directory for decompiled JARs
├── Projects of WARS/           # Output directory for decompiled WARs
└── README.md                   # This file
```

## Examples

### Example 1: Batch Process Multiple JARs

```powershell
# Place all JAR files in .\jars directory
.\decompile_jar.ps1

# Output will show progress for each file:
# Processing file 1 of 3: app-service-v1.0.jar
# [SUCCESS] Completed: app-service-v1.0.jar
```

### Example 2: Extract JAR from Docker Image

```powershell
# Extract JAR
.\Extract-JAR-From-TAR.ps1

# Output: .\jars\myapp-1.0.jar
```

### Example 3: Complete Workflow

```powershell
# 1. Extract JAR from Docker image
.\Extract-JAR-From-TAR.ps1

# 2. Decompile the extracted JAR
.\decompile_jar.ps1

# 3. Open the decompiled project
cd ".\Projects of JARS\myapp-1.0_source"
```

## Troubleshooting

### Java Not Found
**Error**: "java command not found"

**Solution**: Install Java JRE/JDK and ensure it's in your PATH:
```powershell
java -version
```

### tar.exe Not Available
**Error**: "tar.exe is not available"

**Solution**: Upgrade to Windows 10 (version 1803 or later) or Windows 11. Tar is built-in.

### No Classes Found
**Issue**: Script completes but no Java files are generated

**Possible Causes**:
- The JAR/WAR uses a non-standard structure
- The archive is obfuscated or encrypted
- Wrong file type (not a Java application)

**Solution**: Check the temporary extraction directory before cleanup to verify structure.

### CFR Download Fails
**Error**: "Failed to download CFR decompiler"

**Solution**: Manually download cfr.jar from https://github.com/leibnitz27/cfr/releases and place it in the project root.

## Limitations

- Decompiled code may not be identical to original source (variable names, comments lost)
- Obfuscated code will remain obfuscated
- Some advanced Java features may not decompile perfectly
- Generic types may be erased in some cases

## Dependencies

- **CFR (Cass Flow Reduction)**: https://github.com/leibnitz27/cfr
  - Version: 0.152
  - License: MIT License

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.
