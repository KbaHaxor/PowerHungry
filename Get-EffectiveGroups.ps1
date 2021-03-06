Function Get-EffectiveGroups {
  <#

      .SYNOPSIS

      Recursively enumerate groups a specific identity is a member of
      Author: Dennis Maldonado (@DennisMald)
      License: BSD 3-Clause
      Required Dependencies: ActiveDirectory Module cmdlets
      Optional Dependencies: None
      Minimum PowerShell Version = 3.0

      .DESCRIPTION

      Get-EffectiveGroups will list all groups an identity is a member of as well as the parent
      groups of those groups and so on, recursively until all groups are listed (Effective Groups). In otherwords,
      it will unroll nested groups for the identity.

      Get-EffectiveGroup can take an Identity from the parameter or a pipeline

      The -Tree switche changes the output and how Get-EffectiveGroup operates.

      Thanks to @harmj0y for his feedback and of course for PowerView (Great reference)
      <https://github.com/PowerShellMafia/PowerSploit/blob/master/Recon/PowerView.ps1>

      .PARAMETER Identity
      
      Identity of object wanting to list effective groups for. Accepts
      Pipeline input (from SamAccountName)
      Identity can be in the format of SamAccountName, SID, GUID, or 
      Distinguished Name. Identity can search for a User, Group, or Computer
      Defaults to current user identity
     
      .PARAMETER Server

      Domain Controller address to query. Defaults to current domain

      .PARAMETER Tree

      Will print groups out in an hierarchical format to the console (not as objects)
      This will be slower as it is iterating through each group manually and recursively
    
      .PARAMETER NoSelfIdentity

      By default, Group searches will return the identity used to search for groups, even
      if the identity itself is not a group. -NoSelfIdentity will stop this behavior

      .EXAMPLE
      
      PS C:\> Get-EffectiveGroups

      Get Current User's effective groups (nested groups)

      .EXAMPLE
      
      PS C:\> Get-EffectiveGroups -Identity "Domain Admins" -Tree
        
      Get the Domain Admins group's effective groups, output in hierarchical
      format to console
      
      .EXAMPLE
      
      PS C:\> Get-EffectiveGroups -Server foo.local -Identity "JohDoe"

      Get JohnDoe's effective groups from the foo.local domain controller

      .EXAMPLE
      
      PS C:\> Get-ADUser -Identity "JohnDoe" | Get-EffectiveGroups
        
      Get JohnDoe's effective groups via the pipeline method

      .EXAMPLE
      
      PS C:\> Get-ADGroupMember -Identity "Domain Admins" | Get-EffectiveGroups | Export-CSV da-groups.csv
        
      Get the all Domain Admin Groups member's effective groups and output ot a CSV file
      
      .TODO

      - Remove Duplicates from groups list
      - More Verbose output
      - Remove use of AD cmdlets
      - Consider hiding certain local groups (eg: BUILTIN\Users [SID: S-1-5-32-545])
      - When returning identity in object, figure out how to get domain efficiently (currently <UNKNOWN>)
      - The -Identity parameter (alias for SamAccountName) is not showing up for Autocomplete in Powershell.
      - Fix whitespace

  #>
  
  [CmdletBinding()]
    param(
        # Since AD cmdlets output in non-standard ways, Alias and Parameter names needed to be switched
        [Parameter(ValueFromPipelineByPropertyName=$True)]
        [Alias('Identity')]
        [String]
        $SamAccountName,
        
        [String]
        $Server,

        [Switch]
        $Tree,
        
        [Switch]
        $NoSelfIdentity
    )
    
    begin {
      # If -Server is not specifed, default to current domain
      if (! $Server) {
        $CurrentDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name
        $Server = $CurrentDomain
        Write-Verbose "Parameter '-Server' not specified. Setting Server to = $Server"
      }
      
      #Script wide variable for recursion counting when -Tree is specified
      $Script:RecursionCount = 0
    }

    process {
      # If -Identity is not specified nor is there pipeline input, default to current user
      if (! $SamAccountName) {
        $CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $CurrentUserDomain = $CurrentUser.Split('\')[0]
        $CurrentUsername = $CurrentUser.Split('\')[1]
        $SamAccountName = $CurrentUsername
        Write-Verbose "Parameter '-Identity' not specified and no pipleine input found. Setting Identity to = $SamAccountName"
      }
      
      $Identity = $SamAccountName
      Write-Verbose "Identity = $Identity"
      
      # Recursively get all groups for the idenitity, the groups of those groups, etc
      Function Get-ADGroupRecurse {
        $ParentIdentity = $args[0]

        # Print out groups in a hierarchical format (much slower and less information)
        if ($Tree) {
          Get-AdPrincipalGroupMembership -Server $Server -Identity $ParentIdentity | ForEach-Object {
            $Script:RecursionCount += 1
            if ($Script:RecursionCount -gt 1) {
              $Spaces += '    '
            }
            
            $Spaces + $_.SamAccountName
            Get-ADGroupRecurse $_.SamAccountName
            $Script:RecursionCount -= 1
            if ($Script:RecursionCount -ne 0) {
              $Spaces = $Spaces.Substring(0,$Spaces.Length-4) 
            }
          }
        }
                
        else {
          # Allow searching for users or groups
          $ADObject = Get-ADObject -Server $Server -Properties objectSID, SamAccountName -Filter {
            DistinguishedName -EQ $Identity 
            -OR SamAccountName -EQ $Identity
            -OR ObjectGUID -EQ $Identity
            -OR objectSID -EQ $Identity}
        
          Write-Verbose "Getting TokenGroups with Get-ADObject for $Identity"
          if (!$NoSelfIdentity) {
            $SelfIdentityObject = New-Object PSObject
            $SelfIdentityObject | Add-Member NoteProperty 'SamAccountName' $ADObject.SamAccountName
            $SelfIdentityObject | Add-Member NoteProperty 'domain' '<UNKNOWN>'
            $SelfIdentityObject | Add-Member NoteProperty 'objectSID' $ADObject.objectSID
            $SelfIdentityObject | Add-Member NoteProperty 'IdentitySearched' $Identity
            $SelfIdentityObject
          }

          # Return Identity's TokenGroups (unrolled nested groups) as objects
          Write-Verbose "Returning Identity's TokenGroups"
          Write-Verbose $ADObject.DistinguishedName
      
          Get-ADObject -Server $Server -SearchScope Base -SearchBase $ADObject.DistinguishedName -Filter * -Properties tokenGroups | Select-Object -ExpandProperty TokenGroups| ForEach {
            try {
                $TokenSID = $_
                $TokenGroup = New-Object System.Security.Principal.SecurityIdentifier($TokenSID)
                $TokenGroupDomain = $TokenGroup.Translate([System.Security.Principal.NTAccount]).value.Split('\')[0]
                $TokenGroupName = $TokenGroup.Translate([System.Security.Principal.NTAccount]).value.Split('\')[1]
            }
            
            catch {
              Write-Verbose "WARNING: Can not resolve name for SID: $TokenSID"
            }  
            
            $GroupObject = New-Object PSObject
            $GroupObject | Add-Member NoteProperty 'SamAccountName' $TokenGroupName
            $GroupObject | Add-Member NoteProperty 'domain' $TokenGroupDomain
            $GroupObject | Add-Member NoteProperty 'objectSID' $TokenSID
            $GroupObject | Add-Member NoteProperty 'IdentitySearched' $Identity
            $GroupObject    
          }
        }
      }
      Get-ADGroupRecurse $Identity
    }
}
