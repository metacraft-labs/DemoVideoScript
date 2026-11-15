## repro.nim — DemoVideoScript for reprobuild.
##
## DemoVideoScript is consumed as Nim library SOURCE (SC-11 from-source
## consumption): a backend (DemoVideoScript-TermAssert, -GuiAssert) or a
## product's scenario pack puts its `src/` on the Nim path and builds the
## runner with its own binding linked in. Declaring the library lets a
## consumer name it in `uses:`, so a lock pins the revision it was built
## against. The repository's own tests run through its Justfile.
import repro_project_dsl

package demo_video_script:
  defaultToolProvisioning "path"
  uses:
    "nim >=2.0"
  library demo_video_script
  build:
    # Nothing is built here: the library is consumed as source, and the
    # repository's tests run through its Justfile. A package with no
    # `build:` block is not solved, so the lock would record nothing.
    discard
