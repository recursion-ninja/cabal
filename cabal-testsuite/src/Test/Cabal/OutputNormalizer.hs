module Test.Cabal.OutputNormalizer (
    NormalizerEnv (..),
    normalizeOutput,
    ) where

import Data.Monoid (Endo (..))

import Distribution.Version
import Distribution.Text
import Distribution.Pretty
import Distribution.Package
import Distribution.System

import qualified Data.Foldable as F

import Text.Regex

normalizeOutput :: NormalizerEnv -> String -> String
normalizeOutput nenv =
    -- Munge away .exe suffix on filenames (Windows)
    resub "([A-Za-z0-9.-]+)\\.exe" "\\1"
    -- Normalize backslashes to forward slashes to normalize
    -- file paths
  . map (\c -> if c == '\\' then '/' else c)
    -- Install path frequently has architecture specific elements, so
    -- nub it out
  . resub "Installing (.+) in .+" "Installing \\1 in <PATH>"
    -- Things that look like libraries
  . resub "libHS[A-Za-z0-9.-]+\\.(so|dll|a|dynlib)" "<LIBRARY>"
    -- look for PackageHash directories
  . resub "/(([A-Za-z0-9_]+)(-[A-Za-z0-9\\._]+)*)-[0-9a-f]{4,64}/"
          "/<PACKAGE>-<HASH>/"
    -- This is dumb but I don't feel like pulling in another dep for
    -- string search-replace.  Make sure we do this before backslash
    -- normalization!
  . resub (posixRegexEscape (normalizerGblTmpDir nenv) ++ "[a-z0-9\\.-]+") "<GBLTMPDIR>" -- note, after TMPDIR
  . resub (posixRegexEscape (normalizerRoot nenv)) "<ROOT>/"
  . resub (posixRegexEscape (normalizerTmpDir nenv)) "<TMPDIR>/"
  . appEndo (F.fold (map (Endo . packageIdRegex) (normalizerKnownPackages nenv)))
    -- Look for 0.1/installed-0d6uzW7Ubh1Fb4TB5oeQ3G
    -- These installed packages will vary depending on GHC version
    -- Apply this before packageIdRegex, otherwise this regex doesn't match.
  . resub "[0-9]+(\\.[0-9]+)*/installed-[A-Za-z0-9.+]+"
          "<VERSION>/installed-<HASH>"
    -- incoming directories in the store
  . resub "/incoming/new-[0-9]+"
          "/incoming/new-<RAND>"
    -- Normalize architecture
  . resub (posixRegexEscape (display (normalizerPlatform nenv))) "<ARCH>"
    -- Some GHC versions are chattier than others
  . resub "^ignoring \\(possibly broken\\) abi-depends field for packages" ""
    -- Normalize the current GHC version.  Apply this BEFORE packageIdRegex,
    -- which will pick up the install ghc library (which doesn't have the
    -- date glob).
  . (if normalizerGhcVersion nenv /= nullVersion
        then resub (posixRegexEscape (display (normalizerGhcVersion nenv))
                        -- Also glob the date, for nightly GHC builds
                        ++ "(\\.[0-9]+)?")
                   "<GHCVER>"
        else id)
  -- hackage-security locks occur non-deterministically
  . resub "(Released|Acquired|Waiting) .*hackage-security-lock\n" ""
  where
    packageIdRegex pid =
        resub (posixRegexEscape (display pid) ++ "(-[A-Za-z0-9.-]+)?")
              (prettyShow (packageName pid) ++ "-<VERSION>")

data NormalizerEnv = NormalizerEnv
    { normalizerRoot          :: FilePath
    , normalizerTmpDir        :: FilePath
    , normalizerGblTmpDir     :: FilePath
    , normalizerGhcVersion    :: Version
    , normalizerKnownPackages :: [PackageId]
    , normalizerPlatform      :: Platform
    }

posixSpecialChars :: [Char]
posixSpecialChars = ".^$*+?()[{\\|"

posixRegexEscape :: String -> String
posixRegexEscape = concatMap (\c -> if c `elem` posixSpecialChars then ['\\', c] else [c])

resub :: String {- search -} -> String {- replace -} -> String {- input -} -> String
resub search replace s =
    subRegex (mkRegex search) s replace
