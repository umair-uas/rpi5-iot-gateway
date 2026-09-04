# Fourth and final instance of the same wrynose port defect in meta-deepx-m1.
#
# libyuv_git.bb:13 sets S = "${WORKDIR}/git". wrynose oe-core removed the
# base.bbclass shim that used to move sources into WORKDIR (commit 53e9ea30aaf)
# and made it a hard QA error:
#
#   ERROR: Recipes that set S = "${WORKDIR}/git" or S = "${UNPACKDIR}/git"
#   should remove that assignment, as S set by bitbake.conf in oe-core now works.
#
# Note the wording: upstream wants the assignment REMOVED, because oe-core's
# default is now correct. A bbappend cannot delete an assignment, so we set the
# default value explicitly. That also sidesteps the QA check, which matches on
# the two bad literals rather than on the resolved path.
#
# ${BP} is "libyuv-git" here (PV is literally "git"), and the do_unpack log
# confirms the fetcher cloned to .../sources/libyuv-git/ — i.e. exactly
# ${UNPACKDIR}/${BP}. Verified from the failing task log, not assumed.
S = "${UNPACKDIR}/${BP}"

# Why this recipe is in our dependency graph at all: libyuv is a DEPENDS of
# dx-stream, which supplies the GStreamer elements the on-screen DX-M1 demo
# needs. It is unused by the headless dev image, which is why this defect only
# surfaced once the desktop + DEEPX composition was first built.

# --- CMake 4 compatibility --------------------------------------------------
#
# Second defect in the same recipe. libyuv's CMakeLists.txt:6 declares
#
#   CMAKE_MINIMUM_REQUIRED( VERSION 2.8.12 )
#
# and CMake 4 (shipped by wrynose oe-core) removed compatibility with
# pre-3.5 policy levels outright:
#
#   CMake Error at CMakeLists.txt:6 (CMAKE_MINIMUM_REQUIRED):
#     Compatibility with CMake < 3.5 has been removed from CMake.
#     ... Or, add -DCMAKE_POLICY_VERSION_MINIMUM=3.5 to try configuring anyway.
#
# We take CMake's own suggested escape hatch rather than patching upstream
# sources: the flag is declarative, survives a SRCREV bump, and does not fork
# a vendored third-party CMakeLists we have no other reason to touch.
#
# The root cause is the vendor's SRCREV pin (a6a2ec65, early 2024) predating
# CMake 4. Bumping libyuv would also fix it, but that silently changes which
# version of the library the DX-M1 GStreamer elements link against — a bigger
# behavioural change than a policy-compatibility flag. Report upstream; do not
# bump unilaterally.
EXTRA_OECMAKE += "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
