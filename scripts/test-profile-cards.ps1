$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('profile-cards-test-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
Copy-Item -LiteralPath "$root/assets", "$root/scripts", "$root/README.md" -Destination $testRoot -Recurse
$activityScript = Join-Path $testRoot 'scripts/update-activity-cards.ps1'
# Exercise a leap-year rolling window spanning 54 Monday-start weeks.
[IO.File]::WriteAllText($activityScript, ([IO.File]::ReadAllText($activityScript).Replace('[DateTime]::UtcNow.Date', "[DateTime]'2029-01-08'")))
$nugetPath = Join-Path $testRoot 'nuget.json'
@{total=168;packages=@(@{id='One';downloads=123},@{id='Two';downloads=45})} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $nugetPath
$previousAppId = $env:PROFILE_STATS_APP_ID
$previousKey = $env:PROFILE_STATS_APP_PRIVATE_KEY
$previousSummary = $env:GITHUB_STEP_SUMMARY
Remove-Item Env:GITHUB_STEP_SUMMARY -ErrorAction SilentlyContinue
$env:PROFILE_STATS_APP_ID = 'test-app'
$testKey = [Security.Cryptography.RSA]::Create(2048)
$env:PROFILE_STATS_APP_PRIVATE_KEY = $testKey.ExportRSAPrivateKeyPem()
$testKey.Dispose()
$global:ProfileTestGeneration = 1
$global:ProfileTestMalformed = $false
$global:ProfileTestApiFailure = $false
$global:ProfileTestLimitedOwner = $false
$global:ProfileTestOwners = @(Get-Content -Raw "$testRoot/scripts/statistics-owners.json" | ConvertFrom-Json)
$global:ProfileTestIssued = [Collections.Generic.List[string]]::new()
$global:ProfileTestRevoked = [Collections.Generic.List[string]]::new()
$global:ProfileTestTokenOwners = @{}

function Assert-Equal($Actual, $Expected, $Message) {
    if ([string]$Actual -ne [string]$Expected) { throw "$Message`: expected $Expected, got $Actual." }
}
function New-TestRepo($Stars, $Forks, $Issues, $Archived=$false, $IsFork=$false) {
    return @{stargazerCount=$Stars;forkCount=$Forks;issues=@{totalCount=$Issues};isArchived=$Archived;isFork=$IsFork}
}
function Invoke-RestMethod {
    param($Uri, $Headers, $Method, $ContentType, $Body, $TimeoutSec)
    if ($Uri.StartsWith('https://api.github.com/app/installations?')) {
        $installations = @($global:ProfileTestOwners | ForEach-Object {
            @{id=$_;account=@{login=$_};repository_selection=$(if ($global:ProfileTestLimitedOwner -and $_ -eq 'PinguApps') {'selected'} else {'all'})}
        })
        $installations += @{id='unconfigured-owner';account=@{login='unconfigured-owner'};repository_selection='all'}
        return ,$installations
    }
    if ($Uri -match '/app/installations/([^/]+)/access_tokens$') {
        $owner = $Matches[1]
        if ($owner -notin $global:ProfileTestOwners) { throw 'Unconfigured installations must not receive tokens.' }
        $request = $Body | ConvertFrom-Json
        Assert-Equal $request.permissions.contents read 'App token contents access'
        Assert-Equal $request.permissions.issues read 'App token issue access'
        Assert-Equal $request.permissions.pull_requests read 'App token pull request access'
        if ($request.repositories) {
            Assert-Equal $owner pingu2k4 'Public baseline installation'
            Assert-Equal ($request.repositories -join ',') pingu2k4 'Public baseline repository restriction'
            $owner = 'public'
        }
        $token = "test-token-$($global:ProfileTestIssued.Count)"
        $global:ProfileTestIssued.Add($token)
        $global:ProfileTestTokenOwners[$token] = $owner
        return @{token=$token}
    }
    $token = $Headers.Authorization.Substring('Bearer '.Length)
    if ($Uri -eq 'https://api.github.com/installation/token' -and $Method -eq 'Delete') {
        $global:ProfileTestRevoked.Add($token)
        return
    }
    Assert-Equal $Uri 'https://api.github.com/graphql' 'Statistics endpoint'
    $request = $Body | ConvertFrom-Json
    if ($request.query -match '\bviewer\s*\{') { throw 'App queries must target the user explicitly.' }
    $owner = $global:ProfileTestTokenOwners[$token]
    if ($global:ProfileTestApiFailure -and $owner -eq 'PinguApps') { return @{errors=@(@{message='Resource not accessible by integration'})} }
    if ($request.query.Contains('account:')) {
        if ($request.query.Contains('organization(')) { Assert-Equal $owner PinguApps 'Organization repository token routing' }
        else { Assert-Equal $owner pingu2k4 'Personal repository token routing' }
        if ($request.variables.cursor -eq 'personal-next') {
            $connection = @{nodes=@((New-TestRepo 5 2 3));pageInfo=@{hasNextPage=$false}}
        } elseif ($request.variables.cursor -eq 'org-next') {
            $connection = @{nodes=@((New-TestRepo 17 7 11 $true));pageInfo=@{hasNextPage=$false}}
        } elseif ($owner -eq 'pingu2k4') {
            $connection = @{nodes=@((New-TestRepo 3 1 2),(New-TestRepo 999 999 999 $false $true));pageInfo=@{hasNextPage=$true;endCursor='personal-next'}}
        } else {
            $connection = @{nodes=@((New-TestRepo 13 5 7),(New-TestRepo 999 999 999 $false $true));pageInfo=@{hasNextPage=$true;endCursor='org-next'}}
        }
        return @{data=@{account=@{repositories=$connection}}}
    }
    $pr = 90; $issues = 40; $reviews = 50; $commits = 60
    if ($owner -eq 'pingu2k4') { $pr=94+$global:ProfileTestGeneration; $issues=45; $reviews=60; $commits=70 }
    if ($owner -eq 'PinguApps') { $pr=97; $issues=54; $reviews=69; $commits=79 }
    if ($owner -eq 'OmniaBI') { $pr=93; $issues=41; $reviews=51; $commits=62 }
    return @{data=@{user=@{
        login='pingu2k4';createdAt='2015-02-27T13:19:47Z'
        pullRequests=@{totalCount=$pr};issues=@{totalCount=$issues}
        rolling=@{totalPullRequestReviewContributions=$reviews};year=@{totalCommitContributions=$commits}
    }}}
}
function Invoke-WebRequest {
    param($Uri, $Headers, [switch]$UseBasicParsing, $TimeoutSec)
    $year = [int]([regex]::Match($Uri, 'from=(\d{4})').Groups[1].Value)
    $start = [DateTime]::new($year, 1, 1)
    $html = [Text.StringBuilder]::new()
    for ($date=$start; $date -lt $start.AddYears(1); $date=$date.AddDays(1)) {
        $count = if ($date -eq [DateTime]'2029-01-08') { 500 + $global:ProfileTestGeneration } elseif ($date -gt [DateTime]'2029-01-08') { 0 } else { $global:ProfileTestGeneration }
        $id = $date.ToString('yyyyMMdd')
        $label = if (!$count) { 'No contributions on this date.' } else { "$($count.ToString('N0', [Globalization.CultureInfo]::InvariantCulture)) contributions on this date." }
        [void]$html.Append("<td data-date=`"$($date.ToString('yyyy-MM-dd'))`" id=`"$id`"></td><tool-tip for=`"$id`">$label</tool-tip>")
    }
    if ($global:ProfileTestMalformed -and $year -eq 2029) { return @{Content='<td data-date="2029-01-01" id="missing"></td>'} }
    return @{Content=$html.ToString()}
}
function Assert-CardText($Svg, $X, $Y, $Expected) {
    $node = $Svg.SelectSingleNode("//*[local-name()='text' and @x='$X' and @y='$Y']")
    Assert-Equal $node.InnerText $Expected "Card text at $X,$Y"
}

try {
    & $activityScript -NuGetStatsPath $nugetPath
    Assert-Equal $global:ProfileTestIssued.Count ($global:ProfileTestOwners.Count + 1) 'One token per installation plus the public baseline'
    Assert-Equal ($global:ProfileTestRevoked -join ',') ($global:ProfileTestIssued -join ',') 'Every successful token must be revoked'
    $calendar = Get-Content -Raw "$testRoot/scripts/activity-calendar.json" | ConvertFrom-Json
    Assert-Equal $calendar.days.Count 366 'Leap-year day count'
    Assert-Equal $calendar.annual 866 'Rolling contributions'
    Assert-Equal $calendar.lifetime ($calendar.years.psobject.Properties.Value | Measure-Object -Sum).Sum 'Lifetime sum'
    Assert-Equal $calendar.years.'2029' 508 'Current year excludes future dates'
    foreach ($name in @('combined-weekly.svg','combined-weekly-mobile.svg')) {
        [xml]$svg = Get-Content -Raw "$testRoot/assets/cards/$name"
        $mobile = $name.Contains('mobile')
        Assert-CardText $svg 56 182 ($calendar.lifetime.ToString('N0', [Globalization.CultureInfo]::GetCultureInfo('en-GB')))
        Assert-CardText $svg 215 182 8
        Assert-CardText $svg 56 244 105
        Assert-CardText $svg 215 244 80
        Assert-CardText $svg 56 306 91
        Assert-CardText $svg 215 306 60
        Assert-CardText $svg 33 324 'Commits (2029)'
        Assert-CardText $svg $(if ($mobile) {56} else {406}) $(if ($mobile) {418} else {182}) 30
        Assert-CardText $svg $(if ($mobile) {215} else {565}) $(if ($mobile) {418} else {182}) 2
        Assert-CardText $svg $(if ($mobile) {56} else {406}) $(if ($mobile) {480} else {244}) 12
        Assert-CardText $svg $(if ($mobile) {215} else {565}) $(if ($mobile) {480} else {244}) 18
        Assert-CardText $svg $(if ($mobile) {56} else {559}) $(if ($mobile) {617} else {385}) 866
        Assert-CardText $svg 22 $(if ($mobile) {697} else {408}) "Weekly sums $([char]0x00B7) 54 $(if ($mobile) {'weeks'} else {'calendar weeks'})"
        $bars = $svg.SelectNodes("//*[local-name()='rect' and @class='week-bar']")
        Assert-Equal $bars.Count 54 'Dynamic weekly bar count'
        Assert-Equal (($bars | ForEach-Object {[int]$_.GetAttribute('data-count')} | Measure-Object -Sum).Sum) $calendar.annual 'Chart sum'
    }
    foreach ($name in @('highlights.svg','highlights-mobile.svg')) {
        [xml]$svg = Get-Content -Raw "$testRoot/assets/cards/$name"
        $right = if ($name.Contains('mobile')) {192} else {367}
        Assert-CardText $svg 33 145 501
        Assert-CardText $svg $right 145 7
        Assert-CardText $svg 33 222 31
        Assert-CardText $svg $right 222 30
    }
    foreach ($name in @('adoption.svg','adoption-mobile.svg')) {
        [xml]$svg = Get-Content -Raw "$testRoot/assets/cards/$name"
        $mobile = $name.Contains('mobile')
        Assert-CardText $svg 56 147 168
        Assert-CardText $svg $(if ($mobile) {215} else {278}) 147 2
        Assert-CardText $svg $(if ($mobile) {56} else {500}) $(if ($mobile) {209} else {147}) 1
    }
    # Historical revisions and new contributions must refresh, never freeze against the old snapshot.
    $global:ProfileTestGeneration = 2
    & $activityScript -NuGetStatsPath $nugetPath
    $updated = Get-Content -Raw "$testRoot/scripts/activity-calendar.json" | ConvertFrom-Json
    Assert-Equal $updated.annual 1232 'Revised rolling contributions'
    if ($updated.lifetime -le $calendar.lifetime) { throw 'Lifetime total did not refresh.' }
    [xml]$svg = Get-Content -Raw "$testRoot/assets/cards/combined-weekly.svg"
    Assert-CardText $svg 56 244 106
    $before = [IO.File]::ReadAllText("$testRoot/assets/cards/combined-weekly.svg")
    $global:ProfileTestApiFailure = $true
    $failed = $false
    try { & $activityScript -NuGetStatsPath $nugetPath } catch { $failed = $true }
    Assert-Equal $failed $true 'Denied App queries must fail the run'
    Assert-Equal ($global:ProfileTestRevoked -join ',') ($global:ProfileTestIssued -join ',') 'Tokens must also be revoked after API failure'
    Assert-Equal ([IO.File]::ReadAllText("$testRoot/assets/cards/combined-weekly.svg")) $before 'API failure must preserve committed cards'
    $global:ProfileTestApiFailure = $false
    $global:ProfileTestLimitedOwner = $true
    $failed = $false
    try { & $activityScript -NuGetStatsPath $nugetPath } catch { $failed = $true }
    Assert-Equal $failed $true 'Partial repository installations must fail instead of silently undercounting'
    $global:ProfileTestLimitedOwner = $false
    $global:ProfileTestMalformed = $true
    $failed = $false
    try { & $activityScript -NuGetStatsPath $nugetPath } catch { $failed = $true }
    Assert-Equal $failed $true 'Malformed source must fail the run'
    Assert-Equal ([IO.File]::ReadAllText("$testRoot/assets/cards/combined-weekly.svg")) $before 'Malformed source must preserve committed cards'
    Write-Output 'Profile card regression checks passed: App token routing/revocation, public deduplication, installation access failures, every activity/adoption metric, pagination, historical revisions, leap years, 54-week charts, complete periods and malformed calendars.'
} finally {
    if ($null -eq $previousAppId) { Remove-Item Env:PROFILE_STATS_APP_ID } else { $env:PROFILE_STATS_APP_ID = $previousAppId }
    if ($null -eq $previousKey) { Remove-Item Env:PROFILE_STATS_APP_PRIVATE_KEY } else { $env:PROFILE_STATS_APP_PRIVATE_KEY = $previousKey }
    if ($null -ne $previousSummary) { $env:GITHUB_STEP_SUMMARY = $previousSummary }
    # Only remove this uniquely named test directory, under the system temporary directory.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -or (Split-Path $resolved -Leaf) -notlike 'profile-cards-test-*') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
