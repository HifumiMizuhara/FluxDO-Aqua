# fluxdo_render

fluxdo 自研帖子渲染引擎(Node 模型 + 自研选区 + 虚拟化)。

## 状态

阶段 0:底盘建设中。当前仅有空入口 + placeholder widget。

详细方案见主仓 `docs/render_refactor_plan.md`。

## 开发

本仓库设计为 [fluxdo 主仓](https://github.com/Lingyan000/fluxdo) 的 git submodule
挂载在 `packages/fluxdo_render/` 下。

### 单独使用本仓

```bash
git clone git@github.com:Lingyan000/fluxdo_render.git
cd fluxdo_render
flutter pub get
flutter test
```

### 在主仓内开发(推荐)

主仓内会通过 submodule 引入本仓:

```bash
# 初次:
git clone --recursive git@github.com:Lingyan000/fluxdo.git
# 或已 clone 后:
git submodule update --init packages/fluxdo_render
```

直接修改 `packages/fluxdo_render/` 下的代码即可,主仓会通过
workspace 自动联调。修改完成后:

```bash
cd packages/fluxdo_render
git add .
git commit -m "..."
git push

cd ../..  # 回主仓
git add packages/fluxdo_render
git commit -m "chore: bump fluxdo_render"
git push
```

## License

跟随主项目。
