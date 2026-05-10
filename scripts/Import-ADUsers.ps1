<#
.SYNOPSIS
    Importe des utilisateurs Active Directory depuis un fichier CSV.
.DESCRIPTION
    Lit un CSV (Nom, Prenom, Service, Login, MotDePasse), crée les comptes AD
    dans les OUs correspondantes et génère un rapport HTML.
    Auteur : Mohamed Chahid Echattioui (@fzazdbl)
.PARAMETER CsvPath
    Chemin du fichier CSV à importer.
.PARAMETER OURacine
    OU racine où chercher les sous-OUs de département (ex: "OU=Entreprise,DC=lab,DC=local").
.PARAMETER DomainDN
    DN du domaine (détecté automatiquement si vide).
.PARAMETER ReportPath
    Chemin du rapport HTML généré (défaut: .\rapport_import.html).
.PARAMETER WhatIf
    Simulation sans création réelle.
.EXAMPLE
    .\Import-ADUsers.ps1 -CsvPath ".\exemple-users.csv"
    .\Import-ADUsers.ps1 -CsvPath ".\users.csv" -OURacine "OU=Entreprise,DC=lab,DC=local" -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CsvPath,
    [string]$OURacine   = "",
    [string]$DomainDN   = "",
    [string]$ReportPath = ".\rapport_import_$(Get-Date -Format 'yyyyMMdd_HHmmss').html",
    [switch]$WhatIf,
    [switch]$NoReport
)

#Requires -Modules ActiveDirectory

function Write-OK   { param($msg) Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-INFO { param($msg) Write-Host "  [-->] $msg" -ForegroundColor Cyan }
function Write-WARN { param($msg) Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-ERR  { param($msg) Write-Host "  [XX]  $msg" -ForegroundColor Red }

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "  ║       IMPORT AD USERS  |  @fzazdbl               ║" -ForegroundColor Magenta
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""
}

# ── Mapping Service → OU ───────────────────────────────────────────────────────
$ServiceToOU = @{
    "Direction"    = "Direction"
    "RH"           = "RH"
    "IT"           = "IT"
    "Informatique" = "IT"
    "Comptabilite" = "Comptabilite"
    "Comptabilité" = "Comptabilite"
    "Commercial"   = "Commercial"
    "Ventes"       = "Commercial"
}

function Get-TargetOU {
    param([string]$Service, [string]$OURacine)
    $dept = $ServiceToOU[$Service]
    if (-not $dept) {
        Write-WARN "Service inconnu '$Service' — placement dans OU racine"
        return $OURacine
    }
    return "OU=Utilisateurs,OU=$dept,$OURacine"
}

function New-ADUserSafe {
    param(
        [hashtable]$Params,
        [string]$Login,
        [bool]$WhatIfMode
    )
    try {
        $existing = Get-ADUser -Filter "SamAccountName -eq '$Login'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-WARN "Compte existant ignoré : $Login"
            return "skipped"
        }
        if ($WhatIfMode) {
            Write-INFO "[WHATIF] Créerait : $Login dans $($Params.Path)"
            return "whatif"
        }
        New-ADUser @Params -ErrorAction Stop
        Enable-ADAccount -Identity $Login -ErrorAction SilentlyContinue
        Write-OK "Créé : $Login ($($Params.GivenName) $($Params.Surname)) → $($Params.Path)"
        return "created"
    } catch {
        Write-ERR "Erreur création $Login : $_"
        return "error"
    }
}

# ── Rapport HTML ───────────────────────────────────────────────────────────────
function Generate-Report {
    param([array]$Results, [string]$OutputPath, [string]$CsvFile)
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $created = ($Results | Where-Object { $_.Status -eq "created" }).Count
    $skipped = ($Results | Where-Object { $_.Status -eq "skipped" }).Count
    $errors  = ($Results | Where-Object { $_.Status -eq "error" }).Count
    $whatifs = ($Results | Where-Object { $_.Status -eq "whatif" }).Count

    $rows = $Results | ForEach-Object {
        $cls = switch ($_.Status) {
            "created" { "table-success" }
            "skipped" { "table-warning" }
            "error"   { "table-danger" }
            default   { "" }
        }
        "<tr class='$cls'><td>$($_.Login)</td><td>$($_.Prenom) $($_.Nom)</td><td>$($_.Service)</td><td>$($_.OU)</td><td>$($_.Status)</td><td>$($_.Message)</td></tr>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <title>Rapport Import AD — $CsvFile</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css">
  <style>body{background:#0d1117;color:#c9d1d9;font-family:monospace}.card{background:#161b22;border:1px solid #30363d}.card-header{background:#21262d}h1{color:#58a6ff}code{color:#79c0ff}</style>
</head>
<body>
<div class="container-fluid py-4">
  <h1>📋 Rapport Import Active Directory</h1>
  <p class="text-muted">CSV : <code>$CsvFile</code> — Généré le $now</p>
  <div class="row mb-4 g-3">
    <div class="col-md-3"><div class="card text-center p-3"><div style="font-size:2rem;color:#28a745;font-weight:bold">$created</div><small>Créés</small></div></div>
    <div class="col-md-3"><div class="card text-center p-3"><div style="font-size:2rem;color:#ffc107;font-weight:bold">$skipped</div><small>Ignorés (existants)</small></div></div>
    <div class="col-md-3"><div class="card text-center p-3"><div style="font-size:2rem;color:#dc3545;font-weight:bold">$errors</div><small>Erreurs</small></div></div>
    <div class="col-md-3"><div class="card text-center p-3"><div style="font-size:2rem;color:#6ea8fe;font-weight:bold">$whatifs</div><small>Simulation</small></div></div>
  </div>
  <div class="card">
    <div class="card-header"><h5 class="mb-0">Détail des comptes</h5></div>
    <div class="card-body p-0">
      <table class="table table-dark table-hover table-sm mb-0">
        <thead><tr><th>Login</th><th>Nom Prénom</th><th>Service</th><th>OU cible</th><th>Statut</th><th>Message</th></tr></thead>
        <tbody>$($rows -join "`n")</tbody>
      </table>
    </div>
  </div>
  <footer class="mt-4 text-center text-muted" style="font-size:.85rem">
    Généré par Import-ADUsers.ps1 — Mohamed Chahid Echattioui (@fzazdbl)
  </footer>
</div></body></html>
"@
    $html | Out-File -FilePath $OutputPath -Encoding utf8
    Write-OK "Rapport HTML : $OutputPath"
}

# ── Main ───────────────────────────────────────────────────────────────────────
Write-Banner

if (-not (Test-Path $CsvPath)) {
    Write-ERR "Fichier CSV introuvable : $CsvPath"
    exit 1
}

if (-not $DomainDN) {
    try { $DomainDN = (Get-ADDomain).DistinguishedName } catch { Write-ERR "Impossible de détecter le domaine"; exit 1 }
}
if (-not $OURacine) {
    $OURacine = "OU=Entreprise,$DomainDN"
}

Write-INFO "Domaine  : $DomainDN"
Write-INFO "OU racine: $OURacine"
Write-INFO "CSV      : $CsvPath"
if ($WhatIf) { Write-WARN "MODE SIMULATION — aucun compte ne sera créé" }
Write-Host ""

$users = Import-Csv -Path $CsvPath -Encoding UTF8 -Delimiter ";"
Write-INFO "$($users.Count) utilisateur(s) à traiter"
Write-Host ""

$results = @()
$domain_suffix = ($DomainDN -replace "DC=","" -replace ",",".").ToLower()

foreach ($u in $users) {
    $login = $u.Login.Trim()
    $nom   = $u.Nom.Trim()
    $prenom = $u.Prenom.Trim()
    $service = $u.Service.Trim()
    $upn   = "$login@$domain_suffix"
    $targetOU = Get-TargetOU -Service $service -OURacine $OURacine

    # Mot de passe sécurisé
    $pwd = ConvertTo-SecureString $u.MotDePasse.Trim() -AsPlainText -Force

    $adParams = @{
        SamAccountName        = $login
        UserPrincipalName     = $upn
        GivenName             = $prenom
        Surname               = $nom
        DisplayName           = "$prenom $nom"
        Name                  = "$prenom $nom"
        Department            = $service
        Path                  = $targetOU
        AccountPassword       = $pwd
        Enabled               = $true
        PasswordNeverExpires  = $false
        ChangePasswordAtLogon = $true
    }

    $status = New-ADUserSafe -Params $adParams -Login $login -WhatIfMode $WhatIf.IsPresent
    $results += [PSCustomObject]@{
        Login   = $login
        Nom     = $nom
        Prenom  = $prenom
        Service = $service
        OU      = $targetOU
        Status  = $status
        Message = ""
    }
}

# ── Stats ──────────────────────────────────────────────────────────────────────
$created = ($results | Where-Object Status -eq "created").Count
$skipped = ($results | Where-Object Status -eq "skipped").Count
$errors  = ($results | Where-Object Status -eq "error").Count

Write-Host ""
Write-Host "  ────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Résultat :" -ForegroundColor Cyan
Write-Host "    Créés   : $created" -ForegroundColor Green
Write-Host "    Ignorés : $skipped" -ForegroundColor Yellow
Write-Host "    Erreurs : $errors"  -ForegroundColor Red
Write-Host ""

if (-not $NoReport) {
    Generate-Report -Results $results -OutputPath $ReportPath -CsvFile $CsvPath
}
Write-Host ""
