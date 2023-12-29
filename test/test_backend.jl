using Test, DistributedStreams

#_______________________________________________________________________________
# Test fn_ret_type
# Currently this functionality is pretty limited -- so add more tests when they
# are expanded
#-------------------------------------------------------------------------------

a(i) = Int64(1)
@test DistributedStreams.fn_ret_type(a, Any) == Int64

#-------------------------------------------------------------------------------
