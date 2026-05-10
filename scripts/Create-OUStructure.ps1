<#
.SYNOPSIS
    Crée une arborescence d'OUs Active Directory standard.
.DESCRIPTION
    Crée les OUs de premier niveau (Direction, RH, IT, Comptabilite, Commercial)
    avec les sous-OUs Utilisateurs, Ordinateurs et Groupes dans chaque département.
    Auteur : Mohamed Chahid Echattioui (@fzazdbl)
.PARAMETER DomainDN
    DN de base du domaine. Détecté automatiquement si non spécifié.
.PARAMETER OUName
    Nom de l'OU racine de l'entreprise (défaut: "Entreprise").
.PARAMETER WhatIf
    Simulation sans création réelle.
.EXAMPLE
    .\Create-OUStructure.ps1
    .\Create-OUStructure.ps1 -DomainDN "DC=lab,DC=local" -OUName "MaSociete"
    .\Create-OUStructure.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DomainDN   = "",
    [string]$OUName     = "Entreprise",
    [switch]$WhatIf
)

#Requires -Modules ActiveDirectory

# ── Couleurs console ───────────────────────────────────────────────────────────
function Write-OK   { param($msg) Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-INFO { param($msg) Write-Host "  [-->] $msg" -ForegroundColor Cyan }
function Write-WARN { param($msg) Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-ERR  { param($msg) Write-Host "  [XX]  $msg" -ForegroundColor Red }

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "  ║       CREATE OU STRUCTURE  |  @fzazdbl           ║" -ForegroundColor Magenta
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""
}

# ── Détection domaine ──────────────────────────────────────────────────────────
function Get-DomainDN {
    try {
        $domain = Get-ADDomain -ErrorAction Stop
        return $domain.DistinguishedName
    } catch {
        Write-ERR "Impossible de détecter le domaine : $_"
        exit 1
    }
}

# ── Création d'une OU avec vérification ───────────────────────────────────────
function New-OUSafe {
    param(
        [string]$Name,
        [string]$Path,
        [string]$Description = ""
    )
    $dn = "OU=$Name,$Path"
    try {
        $existing = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-WARN "Existe déjà : OU=$Name,$Path"
            return $false
        }
        if ($WhatIf) {
            Write-INFO "[WHATIF] Créerait OU=$Name sous $Path"
            return $true
        }
        $params = @{
            Name                            = $Name
            Path                            = $Path
            Description                     = $Description
            ProtectedFromAccidentalDeletion = $true
            ErrorAction                     = "Stop"
        }
        New-ADOrganizationalUnit @params
        Write-OK "Créé : OU=$Name,$Path"
        return $true
    } catch {
        Write-ERR "Erreur création OU=$Name,$Path : $_"
        return $false
    }
}

# ── Structure ──────────────────────────────────────────────────────────────────
$Departments = @{
    "Direction"    = "Direction générale et management"
    "RH"           = "Ressources Humaines"
    "IT"           = "Département Informatique"
    "Comptabilite" = "Comptabilité et Finance"
    "Commercial"   = "Direction Commerciale et Ventes"
}

$SubOUs = @(
    @{ Name = "Utilisateurs";  Desc = "Comptes utilisateurs" }
    @{ Name = "Ordinateurs";   Desc = "Postes de travail et serveurs" }
    @{ Name = "Groupes";       Desc = "Groupes de sécurité et distribution" }
    @{ Name = "ServiceAccounts"; Desc = "Comptes de service" }
)

$SpecialOUs = @(
    @{ Name = "Serveurs";           Desc = "Serveurs de l'infrastructure" }
    @{ Name = "_Admin";             Desc = "Comptes d'administration (Tier 0)" }
    @{ Name = "_ServiceAccounts";   Desc = "Comptes de service globaux" }
    @{ Name = "_Groupes_Globaux";   Desc = "Groupes globaux inter-départements" }
)

# ── Main ───────────────────────────────────────────────────────────────────────
Write-Banner

if (-not $DomainDN) {
    $DomainDN = Get-DomainDN
}
Write-INFO "Domaine cible : $DomainDN"
Write-INFO "OU racine     : $OUName"
if ($WhatIf) { Write-WARN "MODE SIMULATION (WhatIf) — aucune modification réelle" }
Write-Host ""

$stats = @{ Created = 0; Skipped = 0; Errors = 0 }

# OU racine entreprise
$rootPath = $DomainDN
$rootOU   = "OU=$OUName,$rootPath"
$result = New-OUSafe -Name $OUName -Path $rootPath -Description "OU racine de l'entreprise"
if ($result) { $stats.Created++ } else { $stats.Skipped++ }

# OUs spéciales (admin, serveurs, etc.)
Write-Host ""
Write-INFO "=== OUs spéciales ==="
foreach ($ou in $SpecialOUs) {
    $result = New-OUSafe -Name $ou.Name -Path $rootOU -Description $ou.Desc
    if ($result) { $stats.Created++ } else { $stats.Skipped++ }
}

# Départements + sous-OUs
Write-Host ""
Write-INFO "=== Départements ==="
foreach ($dept in $Departments.GetEnumerator()) {
    $deptPath = $rootOU
    $deptOU   = "OU=$($dept.Key),$deptPath"

    $result = New-OUSafe -Name $dept.Key -Path $deptPath -Description $dept.Value
    if ($result) { $stats.Created++ } else { $stats.Skipped++ }

    foreach ($sub in $SubOUs) {
        $result = New-OUSafe -Name $sub.Name -Path $deptOU -Description "$($sub.Desc) — $($dept.Key)"
        if ($result) { $stats.Created++ } else { $stats.Skipped++ }
    }
    Write-Host ""
}

# ── Récapitulatif ──────────────────────────────────────────────────────────────
Write-Host "  ────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Résultat :" -ForegroundColor Cyan
Write-Host "    OUs créées  : $($stats.Created)" -ForegroundColor Green
Write-Host "    OUs ignorées: $($stats.Skipped)" -ForegroundColor Yellow
Write-Host "    Erreurs     : $($stats.Errors)"  -ForegroundColor Red
Write-Host ""

if (-not $WhatIf) {
    Write-OK "Structure OU créée avec succès dans $DomainDN"
} else {
    Write-WARN "Simulation terminée. Retirez -WhatIf pour créer réellement."
}
Write-Host ""
