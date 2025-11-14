$directoryPath = Read-Host "Enter the directory path"

function Run-Fetch($folder)
{
    if (Test-Path -Path (Join-Path -Path $folder.FullName -ChildPath ".git")) {
        $currentBranch = (git -C $folder.FullName branch --show-current).Trim()
        git -C $folder.FullName pull origin $currentBranch --rebase
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Git pull successful."
        } else {
            Write-Host "Git pull failed."
        }
    } else {
        Write-Host $folder.FullName
        Write-Host "The current directory is not a Git repository."
        Map-Fetch $folder.GetDirectories()
    }
}

function Map-Fetch($folders)
{
    foreach ($folder in $folders) {
        Run-Fetch($folder)
    }
}

Map-Fetch(Get-ChildItem -Path $directoryPath -Directory)