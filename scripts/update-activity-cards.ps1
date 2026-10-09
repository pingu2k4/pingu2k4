param([Parameter(Mandatory)][string]$NuGetStatsPath)

$ErrorActionPreference = 'Stop'
if (!$env:GH_TOKEN) { throw 'PROFILE_STATS_TOKEN is required for account and repository statistics.' }
$root = Split-Path $PSScriptRoot -Parent
$output = Join-Path $root 'assets/cards'
$calendarPath = Join-Path $PSScriptRoot 'activity-calendar.json'
. (Join-Path $PSScriptRoot 'contribution-calendar.ps1')
$nuget = Get-Content -Raw -Encoding UTF8 -LiteralPath $NuGetStatsPath | ConvertFrom-Json
$today = [DateTime]::UtcNow.Date
$year = $today.Year
$from = $today.AddYears(-1).AddDays(1).ToString("yyyy-MM-dd'T'00:00:00'Z'")
$to = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

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
  rolling:contributionsCollection(from:$from,to:$to){totalPullRequestReviewContributions}
  year:contributionsCollection(from:$yearFrom,to:$to){totalCommitContributions}
 }
 organization(login:"PinguApps"){repositories(first:100){pageInfo{hasNextPage endCursor}nodes{isFork isArchived stargazerCount forkCount issues(states:OPEN){totalCount}}}}
}
'@
$data = Invoke-GraphQL $query @{from=$from;to=$to;yearFrom="$year-01-01T00:00:00Z"}
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
$calendar = Get-ProfileCalendar ([DateTime]$data.viewer.createdAt) $today
$days = $calendar.days

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
    $weekLabel = if ($mobile) { 'weeks' } else { 'calendar weeks' }
    Set-CardText $svg 22 $(if ($mobile) { 697 } else { 408 }) "Weekly sums $([char]0x00B7) $($buckets.Count) $weekLabel"
    $bars = $svg.SelectNodes("//*[local-name()='rect' and @class='week-bar']")
    $parent = $bars[0].ParentNode
    $template = $bars[0].CloneNode($true)
    foreach ($bar in $bars) { [void]$parent.RemoveChild($bar) }
    $left = if ($mobile) { 58 } else { 64 }
    $width = if ($mobile) { 274 } else { 590 }
    $step = $width / $buckets.Count
    $height = if ($mobile) { 100 } else { 110 }
    $bottom = if ($mobile) { 815 } else { 540 }
    for ($i=0; $i -lt $buckets.Count; $i++) {
        $bar = $template.CloneNode($true)
        $barHeight = $buckets[$i].count / $maximum * $height
        $bar.SetAttribute('x', ($left + $i * $step).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture))
        $bar.SetAttribute('width', ($step * 0.8).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture))
        $bar.SetAttribute('y', ($bottom - $barHeight).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture))
        $bar.SetAttribute('height', $barHeight.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture))
        $bar.SetAttribute('data-date', $buckets[$i].date)
        $bar.SetAttribute('data-count', [string]$buckets[$i].count)
        $bar.FirstChild.InnerText = "Week of $($buckets[$i].date): $($buckets[$i].count) contributions"
        [void]$parent.AppendChild($bar)
    }
    $axisX = if ($mobile) { 49 } else { 53 }
    $axis = $svg.SelectNodes("//*[local-name()='text' and @x='$axisX']")
    for ($i=0; $i -lt $axis.Count; $i++) { $axis[$i].InnerText = [string]($maximum * $i / 4) }
    $tickY = if ($mobile) { 836 } else { 561 }
    $ticks = $svg.SelectNodes("//*[local-name()='text' and @y='$tickY']")
    for ($i=0; $i -lt $ticks.Count; $i++) { $ticks[$i].InnerText = ([DateTime]$buckets[[Math]::Round($i * ($buckets.Count - 1) / ($ticks.Count - 1))].date).ToString('yy/MM') }
    $svg.SelectSingleNode("//*[local-name()='desc']").InnerText = "Live GitHub profile calendar, including shared private contribution counts. $($calendar.lifetime) all-time contributions; $($calendar.annual) from $($calendar.start) to $($calendar.end), grouped into Monday-start weeks; boundary weeks may be partial."
}
$busiestDay = $days | Sort-Object count -Descending | Select-Object -First 1
$busiestWeek = $buckets | Where-Object { $_.days -eq 7 -and ([DateTime]$_.date).AddDays(7) -le $today } | Sort-Object count -Descending | Select-Object -First 1
$busiestMonth = $months.GetEnumerator() | Where-Object { ($_.Key + '-01') -ge $calendar.start -and ([DateTime]($_.Key + '-01')).AddMonths(1) -le $today } | Sort-Object Value -Descending | Select-Object -First 1
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
    $svg.SelectSingleNode("//*[local-name()='desc']").InnerText = 'Activity highlights calculated daily from the live GitHub profile calendar, including shared private contribution counts.'
    $svg.SelectSingleNode("/*[local-name()='svg']/*[local-name()='title']").InnerText = 'Activity highlights'
    foreach ($title in $svg.SelectNodes("//*[local-name()='g']/*[local-name()='title']")) { $title.InnerText = 'Calculated from the live GitHub profile calendar' }
}
$readmePath = Join-Path $root 'README.md'
$readme = [IO.File]::ReadAllText($readmePath)
$readme = $readme -replace 'Calendar (?:snapshot|updated): \d+ \w+ \d{4}\.', ("Calendar updated: $(([DateTime]$calendar.end).ToString('d MMMM yyyy', $culture)).")
[IO.File]::WriteAllText($readmePath, $readme)
foreach ($name in $documents.Keys) { [IO.File]::WriteAllText((Join-Path $output $name), $documents[$name].OuterXml) }
[IO.File]::WriteAllText($calendarPath, ($calendar | ConvertTo-Json -Depth 8))
$summary = "Refreshed $($calendar.end): $(Format-Count $calendar.lifetime) all-time contributions; $(Format-Count $calendar.annual) in the last year. Account/repository/package metrics also refreshed."
Write-Output $summary
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary }
