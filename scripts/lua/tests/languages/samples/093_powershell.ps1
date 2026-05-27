param([string]$Name = "demo")

class Widget {
  [string]$Name
  Widget([string]$name) { $this.Name = $name }
  [string] Render([string[]]$Items) {
    return ($Items | Where-Object { $_ } | ForEach-Object { "$($this.Name):$_" }) -join ","
  }
}

try {
  [Widget]::new($Name).Render(@("alpha", "beta"))
} catch {
  Write-Error $_
}
