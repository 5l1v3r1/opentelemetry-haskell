{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent.Async
import Data.Function ((&))
import qualified Data.Text as T
import OpenTelemetry.EventlogStreaming_Internal
import OpenTelemetry.Exporter
import OpenTelemetry.ZipkinExporter
import System.Clock
import System.Environment (getArgs, getEnvironment)
import System.FilePath
import System.IO
import System.Process.Typed
import Text.Printf

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["read", path] -> do
      printf "Sending %s to Zipkin...\n" path
      let service_name = T.pack $ takeBaseName path
      exporter <- createZipkinSpanExporter $ localhostZipkinConfig service_name
      origin_timestamp <- fromIntegral . toNanoSecs <$> getTime Realtime
      work origin_timestamp exporter $ EventLogFilename path
      shutdown exporter
      putStrLn "\nAll done."
    ("run" : program : "--" : args') -> do
      printf "Streaming eventlog of %s to Zipkin...\n" program
      exporter <- createZipkinSpanExporter $ localhostZipkinConfig (T.pack program)
      let pipe = program <> "-opentelemetry.pipe"
      _ <- runProcess $ proc "mkfifo" [pipe]
      env <- (("GHCRTS", "-l -ol" <> pipe) :) <$> getEnvironment -- TODO(divanov): please append to existing GHCRTS instead of overwriting
      p <- startProcess (proc program args' & setEnv env)
      origin_timestamp <- fromIntegral . toNanoSecs <$> getTime Realtime
      restreamer <- async $
        withFile pipe ReadMode (\input ->
          work origin_timestamp exporter $ EventLogHandle input SleepAndRetryOnEOF)
      _ <- waitExitCode p
      wait restreamer
      shutdown exporter
      putStrLn "\nAll done."
    _ -> do
      putStrLn "Usage:"
      putStrLn ""
      putStrLn "  eventlog-to-lightstep read <program.eventlog>"
