# Enzyme developer documentation

## Development of Enzyme and Enzyme.jl together

Normally Enzyme.jl downloads and install Enzyme for the user automatically since Enzyme needs to be built against
Julia bundeled LLVM. In case that you are making updates to Enzyme and want to test them against Enzyme.jl the instructions
below should help you get started.

Start Julia in your development copy of Enzyme.jl

```bash
~/s/Enzyme (master)> julia --project=.
```

Then create a development copy of Enzyme_jll and activate it within.

```julia-repl
julia> using Enzyme_jll
julia> Enzyme_jll.dev_jll()
[ Info: Enzyme_jll dev'ed out to ${JULIA_PKG_DEVDIR}/Enzyme_jll with pre-populated override directory
(Enzyme) pkg> dev Enzyme_jll
Path `${JULIA_PKG_DEVDIR}/Enzyme_jll` exists and looks like the correct package. Using existing path.
```

After restarting Julia:

```julia-repl
julia> Enzyme_jll.dev_jll()
julia> Enzyme_jll.libEnzyme_path
"${JULIA_PKG_DEVDIR}/Enzyme_jll/override/lib/LLVMEnzyme-9.so"
```

On your machine `${JULIA_PKG_DEVDIR}` most likely corresponds to `~/.julia/dev`.
Now we can inspect `"${JULIA_PKG_DEVDIR}/Enzyme_jll/override/lib` and see that there is a copy of `LLVMEnzyme-9.so`,
which we can replace with a symbolic link or a copy of a version of Enzyme.


## Building Enzyme against Julia's LLVM.

Depending on how you installed Julia the LLVM Julia is using will be different.

1. Download from julialang.org (Recommended)
2. Manual build on your machine
3. Uses a pre-built Julia from your system vendor (Not recommended)

To check what LLVM Julia is using use:
```
julia> Base.libllvm_version_string
"9.0.1jl"
```

If the LLVM version ends in a `jl` you a likely using the private LLVM.

In your source checkout of Enzyme:

```bash
mkdir build-jl
cd build-jl
```

### Prebuilt binary from julialang.org

```
LLVM_MAJOR_VER=`julia -e "print(Base.libllvm_version.major)"`
julia -e "using Pkg; pkg\"add LLVM_full_jll@${LLVM_MAJOR_VER}\""
LLVM_DIR=`julia -e "using LLVM_full_jll; print(LLVM_full_jll.artifact_dir)"`
echo "LLVM_DIR=$LLVM_DIR"
cmake ../enzyme/ -G Ninja -DENZYME_EXTERNAL_SHARED_LIB=ON -DLLVM_DIR=${LLVM_DIR} -DLLVM_EXTERNAL_LIT=${LLVM_DIR}/tools/lit/lit.py
```

### Manual build of Julia
```
cmake ../enzyme/ -G Ninja -DENZYME_EXTERNAL_SHARED_LIB=ON -DLLVM_DIR=${PATH_TO_BUILDDIR_OF_JULIA}/usr/lib/cmake/llvm/
```
