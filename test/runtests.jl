using Test

import DistributedStreams


#_______________________________________________________________________________
# Test fn_ret_type
#-------------------------------------------------------------------------------

a(i) = Int64(1)
@test DistributedStreams.fn_ret_type(a, Any) == Int64
