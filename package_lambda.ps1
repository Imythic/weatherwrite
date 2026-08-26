Param(
    [string]$OutZip = "weatherwrite-generator.zip"
)

Write-Output "Packaging Lambda into $OutZip"
Push-Location $PSScriptRoot
if (Test-Path $OutZip) { Remove-Item $OutZip }
Compress-Archive -Path "lambda\*" -DestinationPath $OutZip -Force
Write-Output "Created: $OutZip"
Pop-Location
