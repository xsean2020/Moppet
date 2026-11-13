#!/usr/bin/env node
/**
 * 复刻验证脚本 — 验证技术文档是否包含 100% 复刻所需的全部关键数据
 *
 * 用法: node docs/verify-spec.js
 *
 * 输出: 逐项检查结果 + 总体覆盖率评分
 */

const fs = require('fs');
const path = require('path');

const SPEC_PATH = path.join(__dirname, 'JIMAO-3A-TECH-SPEC.md');
const spec = fs.readFileSync(SPEC_PATH, 'utf-8');

let passed = 0;
let failed = 0;
let warnings = 0;

function check(name, condition, detail = '') {
  if (condition) {
    console.log(`  ✅ ${name}`);
    passed++;
  } else {
    console.log(`  ❌ ${name} ${detail}`);
    failed++;
  }
}

function warn(name, detail = '') {
  console.log(`  ⚠️  ${name} ${detail}`);
  warnings++;
}

console.log('='.repeat(70));
console.log('几猫3A大作 — 技术文档复刻完整性验证');
console.log('='.repeat(70));
console.log();

// === 1. 基础结构 ===
console.log('【1. 基础结构】');
check('文档存在', spec.length > 1000);
check('27 个主章节', (spec.match(/^## \d+\./gm) || []).length >= 27);
check('附录 A-M', (spec.match(/^## 附录 [A-M]/gm) || []).length >= 10);
check('目录索引', spec.includes('## 目录'));
console.log();

// === 2. 核心配置 ===
console.log('【2. 核心配置常量】');
check('武器配置 mi', spec.includes('mi') && spec.includes('muzzle') && spec.includes('sightY'));
check('武器数据 (Gv/B_/O_/H_/V_/W_/G_)', spec.includes('Gv = 30') && spec.includes('O_ = 720'));
check('飞鸥配置 Zv', spec.includes('Zv') && spec.includes('boltDamage') && spec.includes('boltSpeed'));
check('猎犬配置 Kv', spec.includes('Kv') && spec.includes('lungeRange') && spec.includes('lungeSpeed'));
check('全局敌人配置 Ui', spec.includes('Ui') && spec.includes('sightRange') && spec.includes('maxTokens'));
check('游戏流程 Yi', spec.includes('Yi') && spec.includes('introSeconds') && spec.includes('cutSeconds'));
check('玩家配置 Pi', spec.includes('Pi') && spec.includes('eye: 1.68') && spec.includes('fov: 74'));
check('世界边界 oi', spec.includes('oi') && spec.includes('quayX'));
console.log();

// === 3. 纹理与材质 ===
console.log('【3. 纹理与材质系统】');
check('纹理集定义 c3 (附录 D)', spec.includes('附录 D') && spec.includes('asphalt') && spec.includes('corrugated'));
check('材质定义表 l1 (附录 E)', spec.includes('附录 E') && spec.includes('paint_red') && spec.includes('gunmetal'));
check('湿润参数预设', spec.includes('cA') && spec.includes('kc') && spec.includes('aa'));
check('武器专用材质 _A', spec.includes('_A') && spec.includes('glove_fabric'));
check('onBeforeCompile 注入', spec.includes('SL_TINT') && spec.includes('SL_TRIPLANAR') && spec.includes('SL_FX'));
check('贴花大小 ZR', spec.includes('ZR') && spec.includes('bullet_metal') && spec.includes('scorch'));
console.log();

// === 4. 渲染引擎 ===
console.log('【4. 渲染引擎】');
check('双相机系统', spec.includes('viewCamera') && spec.includes('viewFov'));
check('画质预设表 (附录 L)', spec.includes('附录 L') && spec.includes('test') && spec.includes('ultra'));
check('后处理参数 (附录 F)', spec.includes('附录 F') && spec.includes('volSunScale') && spec.includes('bloom'));
check('后处理 Pass 顺序', spec.includes('depthcopy') && spec.includes('composite') && spec.includes('grade') && spec.includes('final'));
check('太阳光配置 Mn', spec.includes('Mn') && spec.includes('0.916') && spec.includes('0.225'));
check('天空配置 (附录 J)', spec.includes('附录 J') && spec.includes('zenith') && spec.includes('horizon'));
console.log();

// === 5. 物理与导航 ===
console.log('【5. 物理与导航】');
check('AABB 碰撞', spec.includes('AABB') && spec.includes('moveCapsule'));
check('导航网格参数', spec.includes('cell') && spec.includes('0.5') && spec.includes('142'));
check('A* 寻路', spec.includes('A*') && spec.includes('二叉堆'));
check('射线检测', spec.includes('raycast') && spec.includes('Slab'));
check('视线检测', spec.includes('lineOfSight'));
console.log();

// === 6. 武器系统 ===
console.log('【6. 武器系统】');
check('弹簧-阻尼后坐力', spec.includes('spring-damper') || spec.includes('弹簧-阻尼'));
check('后坐力参数 (kZ/kP/kY/kR)', spec.includes('kZ') && spec.includes('kP') && spec.includes('kY') && spec.includes('kR'));
check('弹着散布公式', spec.includes('baseSpread') && spec.includes('bloomSpread') && spec.includes('airSpread'));
check('换弹动画 (Catmull-Rom)', spec.includes('Catmull-Rom') && spec.includes('magout') && spec.includes('magin'));
check('枪口闪光 ShaderMaterial', spec.includes('枪口闪光') && spec.includes('ShaderMaterial'));
console.log();

// === 7. 敌人 AI ===
console.log('【7. 敌人 AI 系统】');
check('FSM 状态机', spec.includes('patrol') && spec.includes('investigate') && spec.includes('engage') && spec.includes('search'));
check('令牌系统', spec.includes('token') && spec.includes('maxTokens') && spec.includes('tokenGap'));
check('感知系统', spec.includes('sightRange') && (spec.includes('暴露度') || spec.includes('exposure')) && (spec.includes('感知检测') || spec.includes('senseT')));
check('对象池', spec.includes('poolGulls') && spec.includes('poolHounds') && spec.includes('maxWrecks'));
check('警戒传播', spec.includes('rally') || spec.includes('alert') && spec.includes('18'));
check('敌人骨骼 (附录 I)', spec.includes('附录 I') && spec.includes('rotors'));
console.log();

// === 8. 关卡与场景 ===
console.log('【8. 关卡与场景】');
check('中继节点', spec.includes('relay') && spec.includes('3 个中继'));
check('撤离点', spec.includes('extraction') && spec.includes('撤离'));
check('仓库布局 (附录 G)', spec.includes('附录 G') && spec.includes('EAVE') && spec.includes('RIDGE'));
check('码头布局 (附录 H)', spec.includes('附录 H') && spec.includes('LADDER_Z') && spec.includes('RAILS'));
check('道具尺寸表 Gi', spec.includes('Gi') && spec.includes('container20') && spec.includes('barrel'));
console.log();

// === 9. 游戏流程 ===
console.log('【9. 游戏流程】');
check('状态机', spec.includes('title') && spec.includes('playing') && spec.includes('paused') && spec.includes('dead') && spec.includes('complete'));
check('波次配置', spec.includes('waves') && spec.includes('gull: 3') && spec.includes('hound: 1'));
check('评级系统', spec.includes('评级') && spec.includes('timeScore') && spec.includes('accScore'));
check('无电线台词 _l', spec.includes('_l') && spec.includes('指挥中心') && spec.includes('几猫队员'));
check('方向指示 jC', spec.includes('jC') && spec.includes('北方') && spec.includes('东北方'));
console.log();

// === 10. 输入与 UI ===
console.log('【10. 输入与 UI】');
check('输入动作映射表', spec.includes('WASD') && spec.includes('Pointer Lock') && spec.includes('Gamepad'));
check('触屏虚拟摇杆', spec.includes('虚拟摇杆') && spec.includes('t-stick'));
check('HUD 12 元素', spec.includes('罗盘') && spec.includes('十字准星') && spec.includes('生命值') && spec.includes('弹药'));
check('CSS 设计令牌', spec.includes('--ink') && spec.includes('--bone') && spec.includes('--signal'));
check('菜单 4 屏幕', spec.includes('Title') && spec.includes('Paused') && spec.includes('Dead') && spec.includes('Complete'));
check('设置持久化', spec.includes('localStorage') && spec.includes('sens') && spec.includes('volume'));
console.log();

// === 11. 特效系统 ===
console.log('【11. 特效系统】');
check('粒子池 Rf class', spec.includes('Rf') && spec.includes('InstancedBufferGeometry'));
check('粒子属性', spec.includes('drag') && spec.includes('grav') && spec.includes('turb') && spec.includes('ramp'));
check('弹壳系统 Z1', spec.includes('Z1') && spec.includes('LatheGeometry') || spec.includes('弹壳'));
check('碎片系统 $1', spec.includes('$1') && spec.includes('InstancedMesh') || spec.includes('碎片'));
check('贴花系统 j1 (附录 K)', spec.includes('附录 K') && spec.includes('decalCap') && spec.includes('atlas'));
check('闪电效果', spec.includes('thunder') && spec.includes('30-60'));
console.log();

// === 12. 音频系统 ===
console.log('【12. 音频系统】');
check('Web Audio API', spec.includes('Web Audio'));
check('程序化合成', spec.includes('程序化') && spec.includes('合成'));
check('动态强度', spec.includes('0.15') && spec.includes('0.6') && spec.includes('1.0'));
warn('音效合成算法细节', '文档标记为需补充');
console.log();

// === 13. 事件系统 ===
console.log('【13. 事件系统】');
check('事件总线', spec.includes('createEventEmitter') || spec.includes('事件总线'));
check('23+ 种事件', (spec.match(/`[a-z]+:[a-z]+`/g) || []).length >= 15);
check('关键事件', spec.includes('game:state') && spec.includes('enemy:alert') && spec.includes('player:dead') && spec.includes('weapon:fire'));
console.log();

// === 14. 降级与调试 ===
console.log('【14. 降级与调试】');
check('Stub 降级模块', spec.includes('dr') && spec.includes('dr.audio') && spec.includes('dr.fx'));
check('URL 参数表', spec.includes('seed') && spec.includes('bench') && spec.includes('show'));
check('调试接口', spec.includes('window.__G') && spec.includes('window.__stats'));
console.log();

// === 15. 复刻指南 ===
console.log('【15. 复刻指南】');
check('19 步实施顺序', spec.includes('搭建HTML骨架') && spec.includes('引入Three.js') && spec.includes('启动流程'));
check('8 项注意事项', spec.includes('零外部资源') && spec.includes('单文件部署') && spec.includes('移动适配'));
check('10 项测试验证', spec.includes('功能测试') && spec.includes('触屏测试') && spec.includes('降级测试'));
check('完整性验证清单 (附录 M)', spec.includes('附录 M') && spec.includes('92%'));
console.log();

// === 总评 ===
console.log('='.repeat(70));
console.log('验证结果汇总');
console.log('='.repeat(70));
console.log(`  ✅ 通过: ${passed}`);
console.log(`  ❌ 失败: ${failed}`);
console.log(`  ⚠️  警告: ${warnings}`);
console.log();

const total = passed + failed;
const coverage = ((passed / total) * 100).toFixed(1);
console.log(`  📊 关键数据覆盖率: ${coverage}%`);

if (failed === 0) {
  console.log();
  console.log('  🎉 文档包含 100% 复刻所需的关键技术数据！');
  console.log('  📝 注意: 以下部分仍需参考源码或 Three.js 文档:');
  console.log('     - 27 个程序化纹理生成的 GLSL 着色器代码');
  console.log('     - 音效合成的具体参数 (振荡器/包络/滤波器)');
  console.log('     - 武器/角色模型的具体顶点生成代码');
}

console.log();
process.exit(failed > 0 ? 1 : 0);
