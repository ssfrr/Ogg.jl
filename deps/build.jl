using BinDeps

@BinDeps.setup

libogg = library_dependency("libogg", aliases = ["libogg"])

@static if is_apple()
  using Homebrew
  provides( Homebrew.HB, "libogg", libogg, os = :Darwin )
end

provides( AptGet, "libogg0", libogg )

@BinDeps.install Dict(:libogg => :libogg)
