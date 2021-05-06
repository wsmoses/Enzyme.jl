using LLVM
using Libdl
import GPUCompiler: IRError, InvalidIRError

function check_ir(job, args...)
    errors = check_ir!(job, IRError[], args...)
    unique!(errors)
    if !isempty(errors)
        throw(InvalidIRError(job, errors))
    end

    return
end

function check_ir!(job, errors, mod::LLVM.Module)
    for f in functions(mod)
        check_ir!(job, errors, f)
    end

    return errors
end

function check_ir!(job, errors, f::LLVM.Function)
    for bb in blocks(f), inst in instructions(bb)
        if isa(inst, LLVM.CallInst)
            check_ir!(job, errors, inst)
        end
    end

    return errors
end

const libjulia = Ref{Ptr{Cvoid}}(C_NULL)

import GPUCompiler: DYNAMIC_CALL, DELAYED_BINDING, RUNTIME_FUNCTION, UNKNOWN_FUNCTION, POINTER_FUNCTION
import GPUCompiler: backtrace, isintrinsic
function check_ir!(job, errors, inst::LLVM.CallInst)
    bt = backtrace(inst)
    dest = called_value(inst)
    if isa(dest, LLVM.Function)
        fn = LLVM.name(dest)

        # some special handling for runtime functions that we don't implement
        if fn == "jl_get_binding_or_error"
            try
                m, sym, _ = operands(inst)
                sym = first(operands(sym::ConstantExpr))::ConstantInt
                sym = convert(Int, sym)
                sym = Ptr{Cvoid}(sym)
                sym = Base.unsafe_pointer_to_objref(sym)
                push!(errors, (DELAYED_BINDING, bt, sym))
            catch e
                isa(e,TypeError) || rethrow()
                @debug "Decoding arguments to jl_get_binding_or_error failed" inst bb=LLVM.parent(inst)
                push!(errors, (DELAYED_BINDING, bt, nothing))
            end
        elseif fn == "jl_invoke"
            try
                if VERSION < v"1.3.0-DEV.244"
                    meth, args, nargs, _ = operands(inst)
                else
                    f, args, nargs, meth = operands(inst)
                end
                meth = first(operands(meth::ConstantExpr))::ConstantExpr
                meth = first(operands(meth))::ConstantInt
                meth = convert(Int, meth)
                meth = Ptr{Cvoid}(meth)
                meth = Base.unsafe_pointer_to_objref(meth)::Core.MethodInstance
                push!(errors, (DYNAMIC_CALL, bt, meth.def))
            catch e
                isa(e,TypeError) || rethrow()
                @debug "Decoding arguments to jl_invoke failed" inst bb=LLVM.parent(inst)
                push!(errors, (DYNAMIC_CALL, bt, nothing))
            end
        elseif fn == "jl_apply_generic"
            try
                if VERSION < v"1.3.0-DEV.244"
                    args, nargs, _ = operands(inst)
                    ## args is a buffer where arguments are stored in
                    f, args = user.(uses(args))
                    ## first store into the args buffer is a direct store
                    f = first(operands(f::LLVM.StoreInst))::ConstantExpr
                else
                    f, args, nargs, _ = operands(inst)
                end

                f = first(operands(f))::ConstantExpr # get rid of addrspacecast
                f = first(operands(f))::ConstantInt # get rid of inttoptr
                f = convert(Int, f)
                f = Ptr{Cvoid}(f)
                f = Base.unsafe_pointer_to_objref(f)
                push!(errors, (DYNAMIC_CALL, bt, f))
            catch e
                isa(e,TypeError) || rethrow()
                @debug "Decoding arguments to jl_apply_generic failed" inst bb=LLVM.parent(inst)
                push!(errors, (DYNAMIC_CALL, bt, nothing))
            end
        end

    elseif isa(dest, InlineAsm)
        # let's assume it's valid ASM

    elseif isa(dest, ConstantExpr)
        # Enzyme should be able to handle these
        # detect calls to literal pointers
        if occursin("inttoptr", string(dest))
            # extract the literal pointer
            ptr_arg = first(operands(dest))
            GPUCompiler.@compiler_assert isa(ptr_arg, ConstantInt) job
            ptr_val = convert(Int, ptr_arg)
            ptr = Ptr{Cvoid}(ptr_val)

            # look it up in the Julia JIT cache
            frames = ccall(:jl_lookup_code_address, Any, (Ptr{Cvoid}, Cint,), ptr, 0)

            if length(frames) >= 1
                if VERSION >= v"1.4.0-DEV.123"
                    fn, file, line, linfo, fromC, inlined = last(frames)
                else
                    fn, file, line, linfo, fromC, inlined, ip = last(frames)
                end

                # @show fn, file, line, linfo, fromC, inlined, frames, l
                fn = string(fn)
                if ptr == cglobal(:jl_alloc_array_1d)
                    fn = "jl_alloc_array_1d"
                end
                if ptr == cglobal(:jl_alloc_array_2d)
                    fn = "jl_alloc_array_2d"
                end
                if ptr == cglobal(:jl_alloc_array_3d)
                    fn = "jl_alloc_array_3d"
                end
                if ptr == cglobal(:jl_new_array)
                    fn = "jl_new_array"
                end
                if ptr == cglobal(:jl_array_copy)
                    fn = "jl_array_copy"
                end
                if ptr == cglobal(:erf)
                    fn = "erf"
                end
                # if ptr == cglobal(:erfi)
                #     fn = "erfi"
                # end
                # if ptr == cglobal(:erfc)
                #     fn = "erfc"
                # end
                # ptr == reinterpret(UInt64, cglobal(:jl_alloc_array_1d))#
                # @show fn, fromC, ptr, cglobal(:jl_alloc_array_2d), ptr == cglobal(:jl_alloc_array_2d)
                # @show fn, fromC, ptr, reinterpret(UInt64, cglobal(:jl_alloc_array_1d)), reinterpret(UInt64, cglobal(:jl_alloc_array_2d)), reinterpret(UInt64, cglobal(:jl_alloc_array_3d))
                if length(fn) > 1 && fromC 
                    mod = LLVM.parent(LLVM.parent(LLVM.parent(inst)))
                    lfn = LLVM.API.LLVMGetNamedFunction(mod, fn)
                    if lfn == C_NULL
                        lfn = LLVM.API.LLVMAddFunction(mod, fn, LLVM.API.LLVMGetCalledFunctionType(inst))
                    end
                    LLVM.API.LLVMSetOperand(inst, LLVM.API.LLVMGetNumOperands(inst)-1, lfn)
                else
                    # @show inst, fn
                end
            #    push!(errors, (POINTER_FUNCTION, bt, fn))
            #else
            #    push!(errors, (POINTER_FUNCTION, bt, nothing))
            end
        end
    end

    return errors
end
