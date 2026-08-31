# Same wrynose port as dx-driver: the recipe sets S = "${WORKDIR}/git", which
# is a hard QA error since oe-core dropped the source-move compatibility shim
# (53e9ea30aaf). The git fetcher's destsuffix now follows the new S default,
# so the checkout lands at ${UNPACKDIR}/${BP}.
#
# This happens to equal oe-core's own default for S. It is restated rather
# than removed because the recipe sets S explicitly and a bbappend cannot
# unset it — the assignment has to be overridden, not deleted.
S = "${UNPACKDIR}/${BP}"
