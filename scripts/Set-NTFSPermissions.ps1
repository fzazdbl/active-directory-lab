<#
.SYNOPSIS
    Applique des permissions NTFS selon la méthode AGDLP sur des dossiers partagés.
.DESCRIPTION
    Crée les groupes DL (Domain Local) et GL (Global) nécessaires, puis applique
    les ACL NTFS sur les dossiers selon la méthode AGDLP (Account→Global→DomainLocal→Permission).
    Auteur : Mohamed Chahid Echattioui (@fzazdbl)
.PARAMETER ConfigPath
    Fichier JSON de configuration des partages (optionnel — utilise la config intégrée si absent).
.PARAMETER DomainDN
    DN du domaine (détecté automatiquement si vide).
.PARAMETER GroupOU
    OU où créer les groupes (défaut: "OU=_Groupes_Globaux,OU=Entreprise,<DomainDN>").
.PARAMETER WhatIf
    Simulation sans modification réelle.
.EXAMPLE
    .\Set-NTFSPermissions.ps1
    .\Set-NTFSPermissions.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "",
    [string]$DomainDN   = "",
    [string]$GroupOU    = "",
    [switch]$WhatIf
)

#Requires -Modules ActiveDirectory

function Write-OK   { param($msg) Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-INFO { param($msg) Write-Host "  [-->] $msg" -ForegroundColor Cyan }
function Write-WARN { param($msg) Write-Host "  [!!]  $msg" -ForegroundColor Yellow }
function Write-ERR  { param($msg) Write-Host "  [XX]  $msg" -ForegroundColor Red }

function Write-Banner {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "  ║   NTFS PERMISSIONS (AGDLP)  |  @fzazdbl              ║" -ForegroundColor Magenta
    Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""
}

# ── Config par défaut ─────────────────────────────────────────────────────────
$DefaultShares = @(
    @{
        Name    = "Partage_RH"
        Path    = "C:\Partages\RH"
        Groups  = @(
            @{ GL = "GL_RH_Lecture";    DL = "DL_RH_Lecture";    Rights = "ReadAndExecute"; Description = "Lecture RH" }
            @{ GL = "GL_RH_Ecriture";   DL = "DL_RH_Ecriture";   Rights = "Modify";         Description = "Modification RH" }
            @{ GL = "GL_RH_FullControl";DL = "DL_RH_FullControl"; Rights = "FullControl";    Description = "Controle total RH" }
        )
    }
    @{
        Name    = "Partage_IT"
        Path    = "C:\Partages\IT"
        Groups  = @(
            @{ GL = "GL_IT_Lecture";     DL = "DL_IT_Lecture";     Rights = "ReadAndExecute"; Description = "Lecture IT" }
            @{ GL = "GL_IT_Ecriture";    DL = "DL_IT_Ecriture";    Rights = "Modify";         Description = "Modification IT" }
            @{ GL = "GL_IT_FullControl"; DL = "DL_IT_FullControl"; Rights = "FullControl";    Description = "Controle total IT" }
        )
    }
    @{
        Name    = "Partage_Commun"
        Path    = "C:\Partages\Commun"
        Groups  = @(
            @{ GL = "GL_Tous_Lecture";   DL = "DL_Commun_Lecture";  Rights = "ReadAndExecute"; Description = "Lecture tous" }
            @{ GL = "GL_Tous_Ecriture";  DL = "DL_Commun_Ecriture"; Rights = "Modify";         Description = "Modification commun" }
        )
    }
    @{
        Name    = "Partage_Direction"
        Path    = "C:\Partages\Direction"
        Groups  = @(
            @{ GL = "GL_Direction_Lecture";     DL = "DL_Direction_Lecture";     Rights = "ReadAndExecute"; Description = "Lecture Direction" }
            @{ GL = "GL_Direction_FullControl"; DL = "DL_Direction_FullControl"; Rights = "FullControl";    Description = "Controle total Direction" }
        )
    }
)

# ── Création de groupes AD ─────────────────────────────────────────────────────
function New-ADGroupSafe {
    param(
        [string]$Name,
        [string]$Path,
        [string]$Scope,        # Global, DomainLocal, Universal
        [string]$Category,     # Security, Distribution
        [string]$Description,
        [bool]$WhatIfMode
    )
    try {
        $existing = Get-ADGroup -Filter "SamAccountName -eq '$Name'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-WARN "Groupe existant : $Name"
            return $false
        }
        if ($WhatIfMode) {
            Write-INFO "[WHATIF] Créerait groupe $Scope/$Category : $Name"
            return $true
        }
        New-ADGroup -Name $Name -SamAccountName $Name `
            -GroupScope $Scope -GroupCategory $Category `
            -Description $Description -Path $Path `
            -ErrorAction Stop
        Write-OK "Groupe créé : $Name ($Scope)"
        return $true
    } catch {
        Write-ERR "Erreur création groupe $Name : $_"
        return $false
    }
}

# ── AGDLP : ajouter GL dans DL ────────────────────────────────────────────────
function Add-GLtoDL {
    param([string]$GL, [string]$DL, [bool]$WhatIfMode)
    try {
        if ($WhatIfMode) {
            Write-INFO "[WHATIF] Ajouterait $GL dans $DL"
            return
        }
        Add-ADGroupMember -Identity $DL -Members $GL -ErrorAction Stop
        Write-OK "AGDLP : $GL ajouté dans $DL"
    } catch {
        Write-WARN "Impossible d'ajouter $GL dans $DL : $_"
    }
}

# ── ACL NTFS ───────────────────────────────────────────────────────────────────
function Set-FolderACL {
    param(
        [string]$FolderPath,
        [string]$GroupName,
        [string]$Rights,
        [bool]$WhatIfMode
    )
    try {
        if (-not (Test-Path $FolderPath)) {
            if ($WhatIfMode) {
                Write-INFO "[WHATIF] Créerait dossier : $FolderPath"
            } else {
                New-Item -Path $FolderPath -ItemType Directory -Force | Out-Null
                Write-INFO "Dossier créé : $FolderPath"
            }
        }

        if ($WhatIfMode) {
            Write-INFO "[WHATIF] ACL : $GroupName → $Rights sur $FolderPath"
            return
        }

        $acl = Get-Acl -Path $FolderPath
        $domain = (Get-ADDomain).NetBIOSName

        $fileSystemRights = [System.Security.AccessControl.FileSystemRights]$Rights
        $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
        $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
        $accessControlType = [System.Security.AccessControl.AccessControlType]::Allow

        $identity = "$domain\$GroupName"
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity, $fileSystemRights, $inheritanceFlags, $propagationFlags, $accessControlType
        )
        $acl.SetAccessRule($rule)
        Set-Acl -Path $FolderPath -AclObject $acl -ErrorAction Stop
        Write-OK "ACL appliquée : $GroupName → $Rights sur $FolderPath"
    } catch {
        Write-ERR "Erreur ACL sur $FolderPath pour $GroupName : $_"
    }
}

# ── Désactiver héritage et nettoyer ───────────────────────────────────────────
function Disable-Inheritance {
    param([string]$FolderPath, [bool]$WhatIfMode)
    try {
        if ($WhatIfMode) {
            Write-INFO "[WHATIF] Désactiverait l'héritage sur $FolderPath"
            return
        }
        $acl = Get-Acl $FolderPath
        $acl.SetAccessRuleProtection($true, $false)  # Désactive héritage, ne copie pas les ACEs
        Set-Acl -Path $FolderPath -AclObject $acl
        Write-OK "Héritage désactivé : $FolderPath"
    } catch {
        Write-WARN "Impossible de désactiver l'héritage : $_"
    }
}

# ── Main ───────────────────────────────────────────────────────────────────────
Write-Banner

if (-not $DomainDN) {
    try { $DomainDN = (Get-ADDomain).DistinguishedName } catch { Write-ERR "Domaine non détecté"; exit 1 }
}
if (-not $GroupOU) {
    $GroupOU = "OU=_Groupes_Globaux,OU=Entreprise,$DomainDN"
}

Write-INFO "Domaine  : $DomainDN"
Write-INFO "GroupOU  : $GroupOU"
if ($WhatIf) { Write-WARN "MODE SIMULATION — aucune modification réelle" }
Write-Host ""

$shares = if ($ConfigPath -and (Test-Path $ConfigPath)) {
    Get-Content $ConfigPath | ConvertFrom-Json
} else {
    $DefaultShares
}

$stats = @{ Groups = 0; ACLs = 0; Folders = 0 }

foreach ($share in $shares) {
    Write-Host ""
    Write-Host "  ═══ $($share.Name) ═══════════════════════════════════════" -ForegroundColor Cyan

    # Créer le dossier et désactiver l'héritage
    if (-not (Test-Path $share.Path) -and -not $WhatIf) {
        New-Item -Path $share.Path -ItemType Directory -Force | Out-Null
        Write-INFO "Dossier créé : $($share.Path)"
    }
    Disable-Inheritance -FolderPath $share.Path -WhatIfMode $WhatIf.IsPresent

    # SYSTEM et Admins du domaine gardent le Full Control
    if (-not $WhatIf) {
        Set-FolderACL -FolderPath $share.Path -GroupName "Domain Admins" -Rights "FullControl" -WhatIfMode $false
    }

    foreach ($grp in $share.Groups) {
        # 1. Créer le groupe Global (GL)
        $r = New-ADGroupSafe -Name $grp.GL -Path $GroupOU -Scope "Global" -Category "Security" `
            -Description "GL - $($grp.Description)" -WhatIfMode $WhatIf.IsPresent
        if ($r) { $stats.Groups++ }

        # 2. Créer le groupe Domain Local (DL)
        $r = New-ADGroupSafe -Name $grp.DL -Path $GroupOU -Scope "DomainLocal" -Category "Security" `
            -Description "DL - $($grp.Description) - $($share.Name)" -WhatIfMode $WhatIf.IsPresent
        if ($r) { $stats.Groups++ }

        # 3. AGDLP : ajouter GL dans DL
        Add-GLtoDL -GL $grp.GL -DL $grp.DL -WhatIfMode $WhatIf.IsPresent

        # 4. Appliquer ACL NTFS : DL → Permission
        Set-FolderACL -FolderPath $share.Path -GroupName $grp.DL -Rights $grp.Rights -WhatIfMode $WhatIf.IsPresent
        $stats.ACLs++
    }
    $stats.Folders++
}

Write-Host ""
Write-Host "  ────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Résultat :" -ForegroundColor Cyan
Write-Host "    Dossiers traités : $($stats.Folders)"  -ForegroundColor Green
Write-Host "    Groupes créés   : $($stats.Groups)"   -ForegroundColor Green
Write-Host "    ACLs appliquées : $($stats.ACLs)"     -ForegroundColor Green
Write-Host ""
Write-OK "AGDLP configuré. Ajoutez maintenant les utilisateurs dans les groupes GL correspondants."
Write-Host ""
