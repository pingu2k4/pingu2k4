function Get-ProfileGitHubStatistics {
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$PrivateKey,
        [Parameter(Mandatory)][string[]]$Owners,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string]$YearFrom
    )

    function ConvertTo-Base64Url([byte[]]$Bytes) {
        [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
    $payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes((@{iat=$now-60;exp=$now+540;iss=$AppId} | ConvertTo-Json -Compress)))
    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem($PrivateKey)
        $signature = ConvertTo-Base64Url ($rsa.SignData([Text.Encoding]::UTF8.GetBytes("$header.$payload"), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1))
    } finally { $rsa.Dispose() }
    $appHeaders = @{Authorization="Bearer $header.$payload.$signature";Accept='application/vnd.github+json';'User-Agent'='Pingu-profile-cards';'X-GitHub-Api-Version'='2022-11-28'}
    $installations = @()
    for ($page=1; ; $page++) {
        $batch = Invoke-RestMethod -Uri "https://api.github.com/app/installations?per_page=100&page=$page" -Headers $appHeaders -TimeoutSec 30
        $installations += @($batch)
        if (@($batch).Count -lt 100) { break }
    }
    if ('pingu2k4' -notin $Owners -or 'PinguApps' -notin $Owners -or @($Owners | Select-Object -Unique).Count -ne $Owners.Count) {
        throw 'Statistics owners must include pingu2k4 and PinguApps exactly once.'
    }
    $selected = foreach ($owner in $Owners) {
        $installation = @($installations | Where-Object { $_.account.login -eq $owner })
        if ($installation.Count -ne 1 -or $installation[0].suspended_at -or $installation[0].repository_selection -ne 'all') {
            throw "Install the statistics App on all repositories owned by $owner before refreshing cards."
        }
        $installation[0]
    }

    $tokens = [Collections.Generic.List[string]]::new()
    function New-StatisticsToken($Installation, [switch]$PublicOnly) {
        $body = @{permissions=@{contents='read';issues='read';pull_requests='read'}}
        if ($PublicOnly) { $body.repositories = @('pingu2k4') }
        $access = Invoke-RestMethod -Method Post -Uri "https://api.github.com/app/installations/$($Installation.id)/access_tokens" -Headers $appHeaders -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 5 -Compress) -TimeoutSec 30
        if (!$access.token) { throw "No statistics token returned for $($Installation.account.login)." }
        $tokens.Add($access.token)
        return $access.token
    }
    function Invoke-StatisticsQuery($Token, $Query, $Variables) {
        $headers = @{Authorization="Bearer $Token";Accept='application/vnd.github+json';'User-Agent'='Pingu-profile-cards'}
        $response = Invoke-RestMethod -Method Post -Uri 'https://api.github.com/graphql' -Headers $headers -ContentType 'application/json' -Body (@{query=$Query;variables=$Variables} | ConvertTo-Json -Depth 10 -Compress) -TimeoutSec 30
        if ($response.errors -or !$response.data) { throw 'GitHub App statistics query failed; cards have not been updated.' }
        return $response.data
    }
    $profileFields = @'
login createdAt pullRequests{totalCount} issues{totalCount}
rolling:contributionsCollection(from:$from,to:$to){totalPullRequestReviewContributions}
year:contributionsCollection(from:$yearFrom,to:$to){totalCommitContributions}
'@
    $repositoryFields = 'pageInfo{hasNextPage endCursor} nodes{isFork isArchived stargazerCount forkCount issues(states:OPEN){totalCount}}'
    $variables = @{from=$From;to=$To;yearFrom=$YearFrom}
    $query = 'query($from:DateTime!,$to:DateTime!,$yearFrom:DateTime!){user(login:"pingu2k4"){' + $profileFields + '}}'
    try {
        # A token restricted to this public repository provides a common public baseline.
        # Each installation adds only its private delta, so shared public activity counts once.
        $personalInstallation = $selected | Where-Object { $_.account.login -eq 'pingu2k4' }
        $publicToken = New-StatisticsToken $personalInstallation -PublicOnly
        $public = (Invoke-StatisticsQuery $publicToken $query $variables).user
        if ($public.login -ne 'pingu2k4') { throw 'The statistics query did not return pingu2k4.' }
        $metrics = @(
            @{container='pullRequests';field='totalCount'},
            @{container='issues';field='totalCount'},
            @{container='rolling';field='totalPullRequestReviewContributions'},
            @{container='year';field='totalCommitContributions'}
        )
        $profile = $public | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $organization = $null
        foreach ($installation in $selected) {
            $owner = $installation.account.login
            $token = New-StatisticsToken $installation
            $current = (Invoke-StatisticsQuery $token $query $variables).user
            if ($current.login -ne 'pingu2k4') { throw "The $owner installation did not return pingu2k4 statistics." }
            foreach ($metric in $metrics) {
                $container = $metric.container
                $field = $metric.field
                $baseline = $public.$container.$field
                $value = $current.$container.$field
                if ($null -eq $baseline -or $null -eq $value -or $value -lt $baseline) {
                    throw "Incomplete $container statistics from the $owner installation."
                }
                $profile.$container.$field += $value - $baseline
            }
            if ($owner -notin @('pingu2k4','PinguApps')) { continue }
            $actor = if ($owner -eq 'pingu2k4') { 'user(login:"pingu2k4")' } else { 'organization(login:"PinguApps")' }
            $affiliations = if ($owner -eq 'pingu2k4') { ',ownerAffiliations:[OWNER]' } else { '' }
            $nodes = @()
            $cursor = $null
            do {
                $after = if ($cursor) { ',after:$cursor' } else { '' }
                $parameters = if ($cursor) { '($cursor:String!)' } else { '' }
                $pageQuery = 'query' + $parameters + '{account:' + $actor + '{repositories(first:100' + $affiliations + $after + '){' + $repositoryFields + '}}}'
                $connection = (Invoke-StatisticsQuery $token $pageQuery @{cursor=$cursor}).account.repositories
                if (!$connection -or $null -eq $connection.pageInfo.hasNextPage) { throw "Incomplete repository statistics for $owner." }
                $nodes += @($connection.nodes)
                if ($connection.pageInfo.hasNextPage -and (!$connection.pageInfo.endCursor -or $connection.pageInfo.endCursor -eq $cursor)) {
                    throw "Repository pagination did not advance for $owner."
                }
                $cursor = $connection.pageInfo.endCursor
            } while ($connection.pageInfo.hasNextPage)
            $repositories = [pscustomobject]@{nodes=$nodes}
            if ($owner -eq 'pingu2k4') { $profile | Add-Member -NotePropertyName repositories -NotePropertyValue $repositories }
            else { $organization = [pscustomobject]@{repositories=$repositories} }
        }
        return [pscustomobject]@{viewer=$profile;organization=$organization}
    } finally {
        foreach ($token in $tokens) {
            try {
                Invoke-RestMethod -Method Delete -Uri 'https://api.github.com/installation/token' -Headers @{Authorization="Bearer $token";'User-Agent'='Pingu-profile-cards'} -TimeoutSec 30 | Out-Null
            } catch { Write-Warning 'A statistics token could not be revoked; it will expire automatically within one hour.' }
        }
    }
}
