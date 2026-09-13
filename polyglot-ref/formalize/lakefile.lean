import Lake
open Lake DSL

package «fano1» where
  leanOptions := #[
    ⟨`pp.unicode.fun, true⟩,
    ⟨`linter.unusedVariables, false⟩
  ]

@[default_target]
lean_lib Fano1 where
  roots := #[
    `Fano1.Module1.FixedPoint,
    `Fano1.Module1.RNE,
    `Fano1.Module1.FloorInvariance,
    `Fano1.Module1.ErrorBound,
    `Fano1.Module1.Orthogonality,
    `Fano1.Module1.Verification,
    `Fano1.Module2.BiComplex,
    `Fano1.Module2.Projection,
    `Fano1.Module3.Folding,
    `Fano1.Module3.Reconstruction,
    `Fano1.Module4.DefectCharge,
    `Fano1.Module4.PhaseLock,
    `Fano1.Module5.Orthogonality,
    `Fano1.Module5.RootProjection,
    `Fano1.All
  ]
