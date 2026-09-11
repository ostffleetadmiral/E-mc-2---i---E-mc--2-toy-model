import Lake
open Lake DSL

package «emc2-toy-model» where
  leanOptions := #[
    ⟨`pp.unicode.fun, true⟩,
    ⟨`linter.unusedVariables, false⟩
  ]

@[default_target]
lean_lib Emc2ToyModel where
  roots := #[
    `Emc2ToyModel.Module1.FixedPoint,
    `Emc2ToyModel.Module1.RNE,
    `Emc2ToyModel.Module1.ErrorBound,
    `Emc2ToyModel.Module2.Octonion,
    `Emc2ToyModel.Module2.FanoPlane,
    `Emc2ToyModel.Module3.E8Roots,
    `Emc2ToyModel.Module3.SO10,
    `Emc2ToyModel.Module3.Scaling,
    `Emc2ToyModel.All
  ]
