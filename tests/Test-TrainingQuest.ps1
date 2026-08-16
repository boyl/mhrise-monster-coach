$ErrorActionPreference = 'Stop'
$questPath = Join-Path $PSScriptRoot '..\reframework\quests\q200032001.json'
$quest = Get-Content -Raw -LiteralPath $questPath | ConvertFrom-Json

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "$Message：预期 $Expected，实际 $Actual"
    }
}

Assert-Equal $quest.QuestID 200032001 'Quest ID 必须独立且稳定'
Assert-Equal $quest.QuestData.Map 14 '地图必须为塔之秘境'
Assert-Equal $quest.QuestData.EnemyLevel 3 '怪物等级必须为大师等级'
Assert-Equal $quest.QuestData.TargetMonsters[0] 32 '目标必须为轰龙'
Assert-Equal $quest.QuestData.Monsters[0].Id 32 '首个生成怪物必须为轰龙'
Assert-Equal $quest.QuestData.ExtraMonsterCount 0 '不得生成额外大型怪物'
Assert-Equal $quest.QuestData.Reward.Zenny 0 '任务金钱奖励必须为零'
Assert-Equal $quest.QuestData.Reward.Points 0 '任务点数奖励必须为零'
Assert-Equal $quest.QuestData.Reward.HRP 0 '任务等级点数奖励必须为零'
Assert-Equal $quest.EnemyData.Monsters.Count 7 '怪物参数数组长度必须符合 QuestLoader 契约'

if ($quest.QuestText.QuestInfo.Language -notcontains 'ZHS') { throw '缺少简体中文任务文本' }
if ($quest.QuestText.QuestInfo.Language -notcontains 'ENG') { throw '缺少英文回退文本' }

'Test-TrainingQuest.ps1: PASS'
