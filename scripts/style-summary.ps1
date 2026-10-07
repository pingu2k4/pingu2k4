param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination
)

$ErrorActionPreference = 'Stop'
$svg = Get-Content -Raw -Encoding UTF8 -LiteralPath $Source
$document = New-Object System.Xml.XmlDocument
$document.LoadXml($svg)
if ($document.DocumentElement.LocalName -ne 'svg' -or $svg -match 'Something went wrong|Could not fetch|API rate limit|Please try again') {
    throw "Card generation failed: $Source"
}

# Colours from the Summary Cards github_dark theme.
$colours = @{
    '#0366d6' = '#EF4444'
    '#77909c' = '#F1F1F3'
    '#0d1117' = '#101014'
    '#2e343b' = '#352027'
    '#8b949e' = '#EF4444'
    '#40c463' = '#EF4444'
}
foreach ($colour in $colours.GetEnumerator()) {
    $svg = $svg.Replace($colour.Key, $colour.Value)
}
$document.LoadXml($svg)
$root = $document.DocumentElement
$background = $root.SelectSingleNode("./*[local-name()='g']/*[local-name()='rect']")
$background.SetAttribute('rx', '10')
$background.SetAttribute('ry', '10')

if ([IO.Path]::GetFileName($Destination) -eq 'pinguapps.svg') {
    $root.SetAttribute('width', '350')
    $root.SetAttribute('height', '220')
    $root.SetAttribute('viewBox', '0 0 350 220')
    $title = $root.SelectSingleNode("./*[local-name()='g']/*[local-name()='text']")
    $title.InnerText = 'PinguApps | Open source'
    $title.SetAttribute('style', '--gpsc-i: 0; font-size: 18px; fill: #EF4444;')
    $logo = $root.SelectSingleNode(".//*[local-name()='g' and @transform='translate(220,20)']")
    if ($logo) { [void]$logo.ParentNode.RemoveChild($logo) }
    foreach ($value in $root.SelectNodes(".//*[local-name()='text' and @x='130']")) {
        $value.SetAttribute('x', '265')
        $value.SetAttribute('text-anchor', 'end')
    }
}
$background.SetAttribute('width', [string]([int]$root.GetAttribute('width') - 2))
$background.SetAttribute('height', [string]([int]$root.GetAttribute('height') - 2))
[IO.File]::WriteAllText((Join-Path (Get-Location) $Destination), $document.OuterXml)
