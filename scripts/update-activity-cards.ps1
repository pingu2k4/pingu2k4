param([Parameter(Mandatory)][string]$NuGetStatsPath)

$ErrorActionPreference = 'Stop'
if (!$env:GH_TOKEN) { throw 'PROFILE_STATS_TOKEN is required; anonymous statistics are not used.' }
$root = Split-Path $PSScriptRoot -Parent
$output = Join-Path $root 'assets/cards'
$calendarPath = Join-Path $PSScriptRoot 'activity-calendar.json'
$calendar = Get-Content -Raw -Encoding UTF8 -LiteralPath $calendarPath | ConvertFrom-Json
$nuget = Get-Content -Raw -Encoding UTF8 -LiteralPath $NuGetStatsPath | ConvertFrom-Json
$today = [DateTime]::UtcNow.Date
$year = $today.Year
$from = $today.AddDays(-364).ToString("yyyy-MM-dd'T'00:00:00'Z'")
$to = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$yearQueries = (2015..$year | ForEach-Object {
    $end = if ($_ -eq $year) { $to } else { "$_-12-31T23:59:59Z" }
    'y{0}:contributionsCollection(from:"{0}-01-01T00:00:00Z",to:"{1}"){{contributionCalendar{{totalContributions}}}}' -f $_,$end
}) -join "`n"

function Invoke-GraphQL($Query, $Variables) {
    $request = @{query=$Query; variables=$Variables} | ConvertTo-Json -Depth 10 -Compress
    $response = $request | gh api graphql --input - | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $response.errors) { throw 'Authenticated GitHub statistics could not be retrieved.' }
    return $response.data
}

$query = @'
query($from:DateTime!,$to:DateTime!,$yearFrom:DateTime!){
 viewer {
  login createdAt pullRequests{totalCount} issues{totalCount}
  repositories(first:100,ownerAffiliations:[OWNER]){pageInfo{hasNextPage endCursor} nodes{isFork isArchived stargazerCount forkCount issues(states:OPEN){totalCount}}}
  rolling:contributionsCollection(from:$from,to:$to){totalPullRequestReviewContributions contributionCalendar{totalContributions weeks{contributionDays{date contributionCount}}}}
  year:contributionsCollection(from:$yearFrom,to:$to){totalCommitContributions}
  YEARS
 }
 organization(login:"PinguApps"){repositories(first:100){pageInfo{hasNextPage endCursor}nodes{isFork isArchived stargazerCount forkCount issues(states:OPEN){totalCount}}}}
}
'@
$data = Invoke-GraphQL ($query.Replace('YEARS', $yearQueries)) @{from=$from;to=$to;yearFrom="$year-01-01T00:00:00Z"}
if ($data.viewer.login -ne 'pingu2k4') { throw 'The statistics token must belong to pingu2k4.' }
foreach ($actor in @($data.viewer, $data.organization)) {
    $connection = $actor.repositories
    $all = @($connection.nodes)
    while ($connection.pageInfo.hasNextPage) {
        $field = if ($actor -eq $data.viewer) { 'viewer' } else { 'organization(login:"PinguApps")' }
        $affiliations = if ($actor -eq $data.viewer) { ',ownerAffiliations:[OWNER]' } else { '' }
        $pageQuery = 'query($cursor:String!){' + $field + '{repositories(first:100,after:$cursor' + $affiliations + '){pageInfo{hasNextPage endCursor}nodes{isFork isArchived stargazerCount forkCount issues(states:OPEN){totalCount}}}}}'
        $page = Invoke-GraphQL $pageQuery @{cursor=$connection.pageInfo.endCursor}
        $connection = if ($actor -eq $data.viewer) { $page.viewer.repositories } else { $page.organization.repositories }
        $all += @($connection.nodes)
    }
    $actor.repositories.nodes = $all
}
$personal = @($data.viewer.repositories.nodes | Where-Object { !$_.isFork })
$org = @($data.organization.repositories.nodes | Where-Object { !$_.isFork })
$active = @($org | Where-Object { !$_.isArchived }).Count
$days = @($data.viewer.rolling.contributionCalendar.weeks.contributionDays | Sort-Object date | ForEach-Object { [pscustomobject]@{date=$_.date;count=[int]$_.contributionCount} })
if ($days.Count -ne 365 -or ($days | Measure-Object -Property count -Sum).Sum -ne $data.viewer.rolling.contributionCalendar.totalContributions) { throw 'Incomplete GitHub contribution calendar.' }
$lookup = @{}
foreach ($day in $days) { $lookup[$day.date] = $day.count }
$overlap = @($calendar.days | Where-Object { $_.date -lt $calendar.end -and $lookup.ContainsKey($_.date) })
$differences = @($overlap | Where-Object { $lookup[$_.date] -ne $_.count })
$calendarReady = $overlap.Count -gt 0 -and $differences.Count -eq 0
if ($calendarReady) {
    $calendar.days = $days
    $calendar.start = $days[0].date
    $calendar.end = $days[-1].date
    $calendar.annual = [int]($days | Measure-Object -Property count -Sum).Sum
    $calendar.capturedAt = [DateTime]::UtcNow.ToString('o')
    $calendar.source = 'Authenticated GitHub GraphQL; reconciled against the signed-in calendar'
    $calendar.automationVerified = $true
} else {
    $message = "Calendar refresh withheld: $($differences.Count) completed dates differ from the signed-in snapshot. Preserving $($calendar.end); other statistics refresh normally."
    Write-Warning $message
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $message }
}
$lifetimeReady = $true
foreach ($pastYear in 2015..($year - 1)) {
    if ($data.viewer."y$pastYear".contributionCalendar.totalContributions -ne $calendar.years."$pastYear") { $lifetimeReady = $false }
}
if ($calendarReady -and $lifetimeReady) {
    $calendar.lifetime = [long]0
    foreach ($pastYear in 2015..$year) { $calendar.lifetime += $data.viewer."y$pastYear".contributionCalendar.totalContributions }
}

$culture = [Globalization.CultureInfo]::GetCultureInfo('en-GB')
function Format-Count($Number) { ([long]$Number).ToString('N0', $culture) }
function Set-CardText($Svg, $X, $Y, $Value) {
    $node = $Svg.SelectSingleNode("//*[local-name()='text' and @x='$X' and @y='$Y']")
    if (!$node) { throw "Missing card text at $X,$Y." }
    $node.InnerText = [string]$Value
}
$documents = @{}
foreach ($name in @('combined-weekly.svg','combined-weekly-mobile.svg','adoption.svg','adoption-mobile.svg','highlights.svg','highlights-mobile.svg')) {
    $svg = New-Object Xml.XmlDocument
    $svg.PreserveWhitespace = $true
    $svg.Load((Join-Path $output $name))
    $documents[$name] = $svg
}
$age = $today.Year - ([DateTime]$data.viewer.createdAt).Year
if ($today -lt ([DateTime]$data.viewer.createdAt).AddYears($age).Date) { $age-- }
foreach ($name in @('combined-weekly.svg','combined-weekly-mobile.svg')) {
    $svg = $documents[$name]
    $mobile = $name.Contains('mobile')
    Set-CardText $svg 56 182 (Format-Count $calendar.lifetime)
    Set-CardText $svg 215 182 (Format-Count ($personal.stargazerCount | Measure-Object -Sum).Sum)
    Set-CardText $svg 56 244 (Format-Count $data.viewer.pullRequests.totalCount)
    Set-CardText $svg 215 244 (Format-Count $data.viewer.rolling.totalPullRequestReviewContributions)
    Set-CardText $svg 56 306 (Format-Count $data.viewer.year.totalCommitContributions)
    Set-CardText $svg 33 324 "Commits ($year)"
    Set-CardText $svg 215 306 (Format-Count $data.viewer.issues.totalCount)
    $left = if ($mobile) { 56 } else { 406 }
    $right = if ($mobile) { 215 } else { 565 }
    $row1 = if ($mobile) { 418 } else { 182 }
    $row2 = if ($mobile) { 480 } else { 244 }
    Set-CardText $svg $left $row1 (Format-Count ($org.stargazerCount | Measure-Object -Sum).Sum)
    Set-CardText $svg $right $row1 (Format-Count $org.Count)
    Set-CardText $svg $left $row2 (Format-Count ($org.forkCount | Measure-Object -Sum).Sum)
    Set-CardText $svg $right $row2 (Format-Count ($org.issues.totalCount | Measure-Object -Sum).Sum)
    $dot = [char]0x00B7
    $metadata = if ($mobile) { "$($personal.Count) personal repositories $dot $age years on GitHub" } else { "pingu2k4 $dot $($personal.Count) repositories $dot $age years on GitHub $dot Company: PinguApps" }
    $metadataY = if ($mobile) { 538 } else { 365 }
    Set-CardText $svg 22 $metadataY $metadata
}
foreach ($name in @('adoption.svg','adoption-mobile.svg')) {
    $svg = $documents[$name]
    $mobile = $name.Contains('mobile')
    Set-CardText $svg 56 147 (Format-Count $nuget.total)
    Set-CardText $svg $(if ($mobile) { 215 } else { 278 }) 147 (Format-Count $nuget.packages.Count)
    Set-CardText $svg $(if ($mobile) { 56 } else { 500 }) $(if ($mobile) { 209 } else { 147 }) (Format-Count $active)
    $svg.SelectSingleNode("//*[local-name()='desc']").InnerText = "$($nuget.total) downloads across $($nuget.packages.Count) NuGet packages owned by pingu2k4. $active active non-fork PinguApps repositories, including private repositories."
}

if ($calendarReady) {
    $weeks = [ordered]@{}
    $months = @{}
    foreach ($day in $days) {
        $date = [DateTime]::ParseExact($day.date, 'yyyy-MM-dd', $culture)
        $monday = $date.AddDays(-(([int]$date.DayOfWeek + 6) % 7)).ToString('yyyy-MM-dd')
        if (!$weeks.Contains($monday)) { $weeks[$monday] = [pscustomobject]@{date=$monday;count=0;days=0} }
        $weeks[$monday].count += $day.count
        $weeks[$monday].days++
        $month = $day.date.Substring(0,7)
        $months[$month] += $day.count
    }
    $buckets = @($weeks.Values)
    $maximum = [Math]::Max(100, [Math]::Ceiling(($buckets | Measure-Object -Property count -Maximum).Maximum / 100) * 100)
    foreach ($name in @('combined-weekly.svg','combined-weekly-mobile.svg')) {
        $svg = $documents[$name]
        $mobile = $name.Contains('mobile')
        Set-CardText $svg $(if ($mobile) { 56 } else { 559 }) $(if ($mobile) { 617 } else { 385 }) (Format-Count $calendar.annual)
        $bars = $svg.SelectNodes("//*[local-name()='rect' and @class='week-bar']")
        if ($bars.Count -ne $buckets.Count) { throw 'Weekly chart bucket count changed.' }
        $height = if ($mobile) { 100 } else { 110 }
        $bottom = if ($mobile) { 815 } else { 540 }
        for ($i=0; $i -lt $bars.Count; $i++) {
            $barHeight = $buckets[$i].count / $maximum * $height
            $bars[$i].SetAttribute('y', ($bottom - $barHeight).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture))
            $bars[$i].SetAttribute('height', $barHeight.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture))
            $bars[$i].SetAttribute('data-date', $buckets[$i].date)
            $bars[$i].SetAttribute('data-count', [string]$buckets[$i].count)
            $bars[$i].FirstChild.InnerText = "Week of $($buckets[$i].date): $($buckets[$i].count) contributions"
        }
        $axisX = if ($mobile) { 49 } else { 53 }
        $axis = $svg.SelectNodes("//*[local-name()='text' and @x='$axisX']")
        for ($i=0; $i -lt $axis.Count; $i++) { $axis[$i].InnerText = [string]($maximum * $i / 4) }
        $tickY = if ($mobile) { 836 } else { 561 }
        $ticks = $svg.SelectNodes("//*[local-name()='text' and @y='$tickY']")
        for ($i=0; $i -lt $ticks.Count; $i++) { $ticks[$i].InnerText = ([DateTime]$buckets[[Math]::Round($i * ($buckets.Count - 1) / ($ticks.Count - 1))].date).ToString('yy/MM') }
        $svg.SelectSingleNode("//*[local-name()='desc']").InnerText = "Includes private GitHub statistics. $($calendar.annual) contributions from $($calendar.start) to $($calendar.end), grouped into Monday-start weeks; first and last weeks are partial."
    }
    $busiestDay = $days | Sort-Object count -Descending | Select-Object -First 1
    $busiestWeek = $buckets | Where-Object days -eq 7 | Sort-Object count -Descending | Select-Object -First 1
    $busiestMonth = $months.GetEnumerator() | Where-Object { $_.Key -gt $calendar.start.Substring(0,7) -and $_.Key -lt $calendar.end.Substring(0,7) } | Sort-Object Value -Descending | Select-Object -First 1
    $last30 = ($days | Where-Object { $_.date -ge $today.AddDays(-30).ToString('yyyy-MM-dd') -and $_.date -lt $today.ToString('yyyy-MM-dd') } | Measure-Object count -Sum).Sum
    foreach ($name in @('highlights.svg','highlights-mobile.svg')) {
        $svg = $documents[$name]
        $right = if ($name.Contains('mobile')) { 192 } else { 367 }
        Set-CardText $svg 33 145 (Format-Count $busiestDay.count)
        Set-CardText $svg 33 177 ([DateTime]$busiestDay.date).ToString('d MMMM yyyy', $culture)
        Set-CardText $svg $right 145 (Format-Count $busiestWeek.count)
        Set-CardText $svg $right 177 ("$(([DateTime]$busiestWeek.date).ToString('d MMM', $culture)) $([char]0x2013) $(([DateTime]$busiestWeek.date).AddDays(6).ToString('d MMM yyyy', $culture))")
        Set-CardText $svg 33 222 (Format-Count $busiestMonth.Value)
        Set-CardText $svg 33 254 ([DateTime]($busiestMonth.Key + '-01')).ToString('MMMM yyyy', $culture)
        Set-CardText $svg $right 222 (Format-Count $last30)
        Set-CardText $svg $right 254 ("$($today.AddDays(-30).ToString('d MMM', $culture)) $([char]0x2013) $($today.AddDays(-1).ToString('d MMM yyyy', $culture))")
        $svg.SelectSingleNode("//*[local-name()='desc']").InnerText = 'Activity highlights calculated from the authenticated contribution calendar, including private contributions.'
    }
    $readmePath = Join-Path $root 'README.md'
    $readme = [IO.File]::ReadAllText($readmePath)
    $readme = $readme -replace 'Calendar snapshot: \d+ \w+ \d{4}\.', ("Calendar snapshot: $(([DateTime]$calendar.end).ToString('d MMMM yyyy', $culture)).")
    [IO.File]::WriteAllText($readmePath, $readme)
}
foreach ($name in $documents.Keys) { [IO.File]::WriteAllText((Join-Path $output $name), $documents[$name].OuterXml) }
if ($calendarReady) { [IO.File]::WriteAllText($calendarPath, ($calendar | ConvertTo-Json -Depth 8)) }
Write-Output 'Refreshed authenticated account/repository statistics and NuGet adoption cards.'
