function ConvertFrom-ProfileCalendar([string]$Html, [int]$Year) {
    $tooltips = @{}
    foreach ($tip in [regex]::Matches($Html, '(?s)<tool-tip\b[^>]*for="(?<id>[^"]+)"[^>]*>(?<text>.*?)</tool-tip>')) {
        $tooltips[$tip.Groups['id'].Value] = [Net.WebUtility]::HtmlDecode($tip.Groups['text'].Value).Trim()
    }
    $days = @(
        foreach ($cell in [regex]::Matches($Html, '<td\b[^>]*data-date="(?<date>\d{4}-\d{2}-\d{2})"[^>]*id="(?<id>[^"]+)"[^>]*>')) {
            $date = $cell.Groups['date'].Value
            if (!$date.StartsWith("$Year-")) { continue }
            $label = $tooltips[$cell.Groups['id'].Value]
            if ($label -match '^([\d,]+) contributions? on ') { $count = [int]($Matches[1] -replace ',', '') }
            elseif ($label -match '^No contributions on ') { $count = 0 }
            else { throw "Missing contribution count for $date." }
            [pscustomobject]@{date=$date; count=$count}
        }
    ) | Sort-Object date
    $start = [DateTime]::new($Year, 1, 1)
    $expected = ($start.AddYears(1) - $start).Days
    if ($days.Count -ne $expected) { throw "Incomplete profile calendar for $Year." }
    for ($i = 0; $i -lt $expected; $i++) {
        if ($days[$i].date -ne $start.AddDays($i).ToString('yyyy-MM-dd')) { throw "Invalid profile calendar date in $Year." }
    }
    return $days
}

function Get-ProfileCalendar([DateTime]$CreatedAt, [DateTime]$Today) {
    $allDays = @()
    $years = [ordered]@{}
    foreach ($year in $CreatedAt.Year..$Today.Year) {
        $url = "https://github.com/users/pingu2k4/contributions?from=$year-01-01&to=$year-12-31"
        $page = Invoke-WebRequest -UseBasicParsing -Uri $url -Headers @{'Accept-Language'='en-GB'} -TimeoutSec 60
        $days = @(ConvertFrom-ProfileCalendar $page.Content $year | Where-Object { $_.date -le $Today.ToString('yyyy-MM-dd') })
        $years["$year"] = [long]($days | Measure-Object count -Sum).Sum
        $allDays += $days
    }
    $start = $Today.AddYears(-1).AddDays(1).ToString('yyyy-MM-dd')
    $rolling = @($allDays | Where-Object { $_.date -ge $start })
    return [pscustomobject]@{
        source = 'Live GitHub profile calendars, including publicly shared private contribution counts'
        capturedAt = [DateTime]::UtcNow.ToString('o')
        start = $rolling[0].date
        end = $rolling[-1].date
        days = $rolling
        annual = [long]($rolling | Measure-Object count -Sum).Sum
        years = $years
        lifetime = [long]($years.Values | Measure-Object -Sum).Sum
        automationVerified = $true
    }
}
