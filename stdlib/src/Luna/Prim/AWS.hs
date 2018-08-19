{-# LANGUAGE OverloadedStrings #-}

module Luna.Prim.AWS where

import Prologue

import Control.Lens     (to)
import Data.ByteString  (ByteString)
import Data.Map         (Map)
import Data.Text        (Text)
import Luna.Std.Builder (LTp (..), makeFunctionIO, integer)
import System.FilePath  ((</>), (<.>))

import qualified Codec.Archive.Zip           as Zip
import qualified Data.Map                    as Map
import qualified Data.Text.IO                as Text
import qualified Luna.IR                     as IR
import qualified Luna.Pass.Sourcing.Data.Def as Def
import qualified Luna.Runtime                as Luna
import qualified Luna.Std.Builder            as Builder
import qualified Network.AWS                 as AWS
import qualified Network.AWS.Lambda          as Lambda
import qualified OCI.Data.Name               as Name
import qualified System.Directory            as Dir

type AWSModule = "Std.AWS"

awsModule :: Name.Qualified
awsModule = Name.qualFromSymbol @AWSModule

exports :: forall graph m. Builder.StdBuilder graph m => m (Map IR.Name Def.Def)
exports = do
    let envT = LCons awsModule "AWSEnv" []

    let listFunsVal :: AWS.Env -> IO ()
        listFunsVal env = do
          funs <- AWS.runResourceT $ AWS.runAWS env
                                   $ AWS.send
                                   $ Lambda.listFunctions
          print funs
    primListFuns <- makeFunctionIO @graph (flip Luna.toValue listFunsVal)
                                          [envT] Builder.noneLT

    let newEnvVal :: IO AWS.Env
        newEnvVal = AWS.newEnv AWS.Discover
    primAWSNewEnv <- makeFunctionIO @graph (flip Luna.toValue newEnvVal)
                                           [] envT

    let invokeVal :: AWS.Env -> Text -> ByteString -> IO Lambda.InvokeResponse
        invokeVal env fname payload =
            let invocation = Lambda.invoke fname payload
            in AWS.runResourceT . AWS.runAWS env . AWS.send $ invocation
        invokeArgsT = [envT, Builder.textLT, Builder.binaryLT]
        invokeRespT = LCons awsModule "LambdaInvokeResponse" []
    primAWSInvoke <- makeFunctionIO @graph (flip Luna.toValue invokeVal)
                                           invokeArgsT invokeRespT

    let zipFunctionCodeVal :: Text -> Text -> IO ()
        zipFunctionCodeVal fname contents = do
            let contentsBS = convertTo @ByteString contents
                dirName    = convertTo @String     fname
                archName   = dirName <.> "zip"
                fileName   = "index" <.> "js"
            s <- Zip.mkEntrySelector (dirName </> fileName)
            let newEntry = Zip.addEntry Zip.Store contentsBS s
            Zip.createArchive archName newEntry
    primZipFunctionCode <- makeFunctionIO @graph
        (flip Luna.toValue zipFunctionCodeVal)
        [Builder.textLT, Builder.textLT] Builder.noneLT

    pure $ Map.fromList [ ("primAWSListFuns",     primListFuns)
                        , ("primAWSNewEnv",       primAWSNewEnv)
                        , ("primAWSInvoke",       primAWSInvoke)
                        , ("primZipFunctionCode", primZipFunctionCode)
                        ]


type instance Luna.RuntimeRepOf AWS.Env =
    Luna.AsNative ('Luna.ClassRep AWSModule "AWSEnv")

type instance Luna.RuntimeRepOf Lambda.InvokeResponse =
    Luna.AsClass Lambda.InvokeResponse
                 ('Luna.ClassRep "Std.AWS" "LambdaInvokeResponse")

instance Luna.ToObject Lambda.InvokeResponse where
    toConstructor imps v = Luna.Constructor "LambdaInvokeResponse"
        [ Luna.toData imps $ v ^. Lambda.irsStatusCode . to integer
        , Luna.toData imps $ v ^. Lambda.irsPayload
        ]