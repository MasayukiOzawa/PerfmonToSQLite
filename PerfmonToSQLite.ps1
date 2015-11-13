<# 
.SYNOPSIS 
パフォーマンスモニターの情報を取得して SQLite のデータベースに書き込む

.DESCRIPTION
JSON に定義されたパフォーマンスモニターの定義を元に、取得した情報を SQLite のデータベースに出力
SQL Server 向けに作成したサンプルのJSONを使用した場合、1 時間のデータ取得で 15MB 程度のファイルが作成される

.NOTES
Author: Masayuki OZAWA

.EXAMPLE
PerfmonToSQLite.ps1 -EndTime (Get-Date).AddHours(2)


.EXAMPLE
PerfmonToSQLite.ps1 -StartTime "2016/1/1 00:00" -EndTime "2016/1/7 00:00"

.LINK
https://github.com/MasayukiOzawa/PerfmonToSQLite
https://www.sqlite.org/
https://system.data.sqlite.org/index.html/doc/trunk/www/index.wiki

#>

[cmdletbinding()]
param(
[parameter(Position=0)]
[string]$ComputerName = $env:COMPUTERNAME,
[parameter(Position=1)]
[int]$Interval = 5,
[parameter(Position=2)]
[datetime]$StartTime = (Get-Date),
[parameter(Position=3)]
[datetime]$EndTime = ($StartTime).AddMinutes(5),
[parameter(Position=4)]
[string]$SQLitePath = (Split-Path $MyInvocation.MyCommand.Path -Parent),
[parameter(Position=5)]
$Counter = (Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) "json\counter.json")
)

Write-Output ("[{0}]:Performance Collection Start" -f (Get-Date))
Write-Output ("*" * 40)
Write-Output ("SQLitePath:[{0}]`nJson:[{1}]`nComputerName:[{2}]`nInterval:[{3}]`nStartTime:[{4}]`nEndTime:[{5}]" -f $SQLitePath, $Counter, $ComputerName, $Interval, $StartTime, $EndTime )
Write-Output ("*" * 40)

$summarytime = (Get-Date).ToString("yyyy/MM/dd HH:mm")

$p = New-Object -TypeName System.Collections.ArrayList

$json = Get-Content $Counter -Encoding UTF8 -Raw | ConvertFrom-Json

foreach($Counter in $json){
    if([System.Diagnostics.PerformanceCounterCategory]::Exists($Counter.CategoryName, $ComputerName)){
        if ($counter.CounterName -ne $null){
            foreach($CounterName in $Counter.CounterName){
                if([System.Diagnostics.PerformanceCounterCategory]::CounterExists($CounterName, $Counter.CategoryName, $ComputerName)){
                    if($Counter.InstanceName -eq $null){
                        [void]$p.Add((New-Object System.Diagnostics.PerformanceCounter($Counter.CategoryName, $CounterName, $null, $ComputerName)))
                    }elseif($Counter.InstanceName -eq "*"){
                        (New-Object System.Diagnostics.PerformanceCounterCategory($Counter.CategoryName,$ComputerName)).GetInstanceNames() `
                        | %{[void]$p.Add((New-Object System.Diagnostics.PerformanceCounter($Counter.CategoryName, $CounterName, $_, $ComputerName)))}
                    }else{
                        if([System.Diagnostics.PerformanceCounterCategory]::InstanceExists($Counter.InstanceName,$Counter.CategoryName, $ComputerName)){
                            [void]$p.Add((New-Object System.Diagnostics.PerformanceCounter($Counter.CategoryName, $CounterName, $Counter.InstanceName, $ComputerName)))
                        }else{
                            Write-Output ("CategoryName[{0}]`tCounterName[{1}]`tInstanceName[{2}] is Nothing" -f $Counter.CategoryName, $CounterName, $Counter.InstanceName)
                        }
                    }
                }else{
                    Write-Output ("CategoryName[{0}]`tCounterName[{1}] is Nothing" -f $Counter.CategoryName,$CounterName)
                }
            }
        }else{
            (New-Object System.Diagnostics.PerformanceCounterCategory($Counter.CategoryName,$ComputerName)).GetInstanceNames() `
            | %{(New-Object System.Diagnostics.PerformanceCounterCategory($Counter.CategoryName,$ComputerName)).GetCounters("$_")} `
            | %{[void]$p.Add((New-Object System.Diagnostics.PerformanceCounter($_.CategoryName, $_.CounterName, $_.InstanceName, $ComputerName)))}
        } 
    }else{
        Write-Output ("CategoryName[{0}] is Nothing" -f $Counter.CategoryName)
    }
}

[void]$p.NextValue()

$result = New-Object -TypeName System.Collections.ArrayList

Add-Type -Path "$($SQLitePath)\System.Data.SQLite.dll"

$constring = New-Object System.Data.SQLite.SQLiteConnectionStringBuilder
$constring.psbase.DataSource = ("$($SQLitePath)\sqlite-{0}.db" -f $ComputerName)

$con = New-Object System.Data.SQLite.SQLiteConnection
$con.ConnectionString = $constring

Write-Output ("`nCurrent Time:[{0}]`nStart Time:[{1}]`nwait....`n" -f (Get-Date), $StartTime)

While($true){
    if((Get-Date) -lt $StartTime){
        Start-Sleep -Seconds 10
    }else{
        break
    }
}

Write-Output ("[{0}]:Performance Collection Start" -f (Get-Date))
Do{

    # CPU 使用率等については即時次の情報を読み取ると正確な値が取得できないため、1 秒スリープする
    # https://msdn.microsoft.com/ja-jp/library/system.diagnostics.performancecounter.nextvalue(v=vs.110).aspx 
    Start-Sleep $Interval

    $p | %{[void]$result.Add([PSCustomObject]@{
        Date=(Get-Date).ToString("HH:mm:ss")
        CategoryName=$_.CategoryName
        CounterName=$_.CounterName
        InstanceName=$_.InstanceName
        Value=[int64]$_.NextValue()
    })}

    if ((Get-Date).ToString("yyyy/MM/dd HH:mm") -ne $summarytime){

        $summary = $result | Group-Object -Property  CounterName,CategoryName,InstanceName `
        | %{[PSCustomObject]@{
            Date=$summarytime
            CategoryName=$_.Group.CategoryName | select -First 1
            CounterName=$_.Group.CounterName | select -First 1
            InstanceName=$_.Group.InstanceName | select -First 1
            Value=[int64]($_.Group | Measure-Object value -Average).Average
        }}
        Write-Verbose ($summary | ft * | Out-String)
        $result.Clear()
        $summarytime = (Get-Date).ToString("yyyy/MM/dd HH:mm")

        $con.Open()

        $stringbuilder = New-Object -TypeName System.Text.StringBuilder
        [void]$stringbuilder.Append("CREATE TABLE IF NOT EXISTS Perfmon(Date TEXT,ComputerName TEXT,CategoryName TEXT, CounterName TEXT, InstanceName TEXT, value INTEGER);")
        [void]$stringbuilder.Append("CREATE INDEX IF NOT EXISTS IX_Perfmon_Date ON Perfmon(Date,CategoryName,CounterName);")
        [void]$stringbuilder.Append("CREATE INDEX IF NOT EXISTS IX_Perfmon_Category_Counter ON Perfmon(CategoryName,CounterName);")
        $sql = $stringbuilder.ToString()

        $cmd = $con.CreateCommand()
        $cmd.CommandText = $sql
        [void]$cmd.ExecuteNonQuery()

        $sql = $summary | %{"INSERT INTO Perfmon VALUES('{0}','{1}','{2}','{3}','{4}',{5});" -f $_.Date, $ComputerName, $_.CategoryName, $_.CounterName, $_.InstanceName, $_.Value }
        $tran = $con.BeginTransaction()
        $sql | %{$cmd.CommandText = $_;[void]$cmd.ExecuteNonQuery()}
        $tran.Commit()

        $con.Close()
    }
}while ((Get-Date) -lt $EndTime)

$con.Dispose()
Write-Output ("[{0}]:Performance Collection Stop" -f (Get-Date))
