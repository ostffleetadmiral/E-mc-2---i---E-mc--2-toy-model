/-
  All.lean — Cross-module import verification

  This file imports all modules to verify cross-module dependencies
  compile cleanly. It serves as the top-level build target.
-/

import Fano1.Module1.FixedPoint
import Fano1.Module1.RNE
import Fano1.Module1.FloorInvariance
import Fano1.Module1.ErrorBound
import Fano1.Module1.Orthogonality
import Fano1.Module1.Verification
import Fano1.Module2.BiComplex
import Fano1.Module2.Projection
import Fano1.Module3.Folding
import Fano1.Module3.Reconstruction
import Fano1.Module4.DefectCharge
import Fano1.Module4.PhaseLock
import Fano1.Module5.Orthogonality
import Fano1.Module5.RootProjection

/-- All modules compile and link successfully. -/
theorem all_modules_compile : True := trivial
