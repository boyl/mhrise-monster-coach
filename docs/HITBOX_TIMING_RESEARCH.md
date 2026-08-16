# 攻击判定时间研究结论

## 结论

轰龙攻击阶段优先从游戏运行时的活动 Hitbox 状态生成，不再把 MOTLIST 离线解析作为主路径。

社区的 MHR HitboxViewer 已证明以下能力可以在 REFramework 中稳定实现：

- 实时读取并显示攻击 Hitbox 与受击 Hurtbox；
- 记录 Attack Log 和 Collision Log；
- 逐帧观察判定盒；
- 调整 TimeScale；
- 读取碰撞资源、RequestSet、形状和攻击参数。

来源：

- <https://www.nexusmods.com/monsterhunterrise/mods/2182>
- <https://github.com/kmy0/MHWildsHitboxViewer>

Nexus 页面明确限制未经许可修改或复用作者资产。公开 GitHub 仓库当前主要面向 Wilds，使用 `app.*` 类型，而 Rise 使用不同的 `snow.*` 运行时类型。因此本项目不复制、改编或打包 HitboxViewer 代码及二进制，只把它作为可行性证据和可选共存工具。

## 数据边界

离线 RCOL 负责稳定身份：

- 碰撞资源路径；
- Resource/RequestSet/Shape 索引；
- 形状、关节和攻击参数；
- 游戏版本与资源校验信息。

运行时采集负责时间事实：

- 当前 `ActionCategory + ActionNo`；
- Motion Bank、Motion ID、名称、当前帧与总帧；
- RequestSet/Collider 从非活动到活动、从活动到非活动的边沿；
- 同一动作中的多段判定窗口；
- 任务、怪物、形态和怒气上下文。

两者通过资源路径与索引关联。任何无法关联的数据保留原始标识，不猜测招式或攻击窗口。

## 稳定契约

运行时采集器输出 `CollisionWindowSample`：

```json
{
  "monster_id": 32,
  "action": { "category": 4, "number": 26 },
  "motion": { "bank": 8, "id": 50, "name": "em032_00_08050" },
  "resource_path": "enemy/em032/00/collision/em032_00_atk_colliders.rcol",
  "resource_index": 0,
  "request_set_index": 12,
  "start_frame": 31.0,
  "end_frame": 47.0,
  "sample_count": 1,
  "source": "runtime_hitbox_edge",
  "status": "observed"
}
```

状态晋级规则：

1. 单次边沿只标记为 `observed`。
2. 同一 Action/Motion/RequestSet 至少三次一致，且窗口差异在容差内，升级为 `repeated`。
3. 与真实受击帧或独立 Hitbox 工具逐帧结果相符后，升级为 `confirmed`。
4. 只有 `confirmed` 能驱动“前摇/生效/收招”和武器专属反制建议。

## 实现顺序

1. 只读枚举 Rise 当前版本中的 RequestSetCollider、ColliderSwitcher 和攻击控制器类型与成员。
2. 优先轮询活动状态；只有轮询缺少边沿信息时才增加无参数篡改的 pre/post hook。
3. 将碰撞边沿与现有 Action/Motion 帧快照合并并自动落盘。
4. 离线汇总重复窗口，并与已存在的被动受击样本交叉验证。
5. 完成轰龙闭环后，把运行时成员名移入版本适配层，而不是写入怪物数据包。

## 安全边界

- 采集器不调用 Enable/Disable、SetRequest、Action 请求或位置写入方法。
- 未确认成员前只输出类型与成员元数据，不安装猜测 Hook。
- 多人任务自动停用采集与所有后续写入能力。
- 外部 HitboxViewer 仅允许用户自行安装并并行核对；本项目不把它设为强制依赖。
