{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE CPP                       #-}
{-# LANGUAGE EmptyDataDecls            #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE ForeignFunctionInterface  #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE TypeSynonymInstances      #-}

------------------------------------------------------------------------------
-- | An internal Snap module containing HTTP types.
--
-- /N.B./ this is an internal interface, please don't write user code that
-- depends on it. Most of these declarations (except for the
-- unsafe/encapsulation-breaking ones) are re-exported from "Snap.Core".
--
module Snap.Internal.Http.Types where

------------------------------------------------------------------------------
import           Blaze.ByteString.Builder
import           Control.Monad            (unless)
import           Data.ByteString          (ByteString)
import qualified Data.ByteString          as S
import qualified Data.ByteString.Char8    as B
import           Data.ByteString.Internal (w2c)
import           Data.CaseInsensitive     (CI)
import qualified Data.CaseInsensitive     as CI
import qualified Data.IntMap              as IM
import           Data.List                hiding (take)
import           Data.Map                 (Map)
import qualified Data.Map                 as Map
import           Data.Maybe
import           Data.Time.Clock
import           Data.Word                (Word64)
import           Foreign.C.Types
import           Prelude                  hiding (take)
import           System.IO
import           System.IO.Streams        (InputStream, OutputStream)
import qualified System.IO.Streams        as Streams

------------------------------------------------------------------------------
#ifdef PORTABLE
import           Data.Time.Clock.POSIX
import           Data.Time.Format
import           Data.Time.LocalTime
import           System.Locale            (defaultTimeLocale)
#else
import qualified Data.ByteString.Unsafe   as S
import           Data.Time.Format         ()
import           Foreign
import           Foreign.C.String
#endif

------------------------------------------------------------------------------
import           Snap.Types.Headers       (Headers)
import qualified Snap.Types.Headers       as H


#ifndef PORTABLE

------------------------------------------------------------------------------
-- foreign imports from cbits
foreign import ccall unsafe "set_c_locale"
        set_c_locale :: IO ()

foreign import ccall unsafe "c_parse_http_time"
        c_parse_http_time :: CString -> IO CTime

foreign import ccall unsafe "c_format_http_time"
        c_format_http_time :: CTime -> CString -> IO ()

foreign import ccall unsafe "c_format_log_time"
        c_format_log_time :: CTime -> CString -> IO ()

#endif


------------------------------------------------------------------------------
-- | A typeclass for datatypes which contain HTTP headers.
class HasHeaders a where
    -- | Modify the datatype's headers.
    updateHeaders :: (Headers -> Headers) -> a -> a

    -- | Retrieve the headers from a datatype that has headers.
    headers       :: a -> Headers


------------------------------------------------------------------------------
-- | Adds a header key-value-pair to the 'HasHeaders' datatype. If a header
-- with the same name already exists, the new value is appended to the headers
-- list.
addHeader :: (HasHeaders a) => CI ByteString -> ByteString -> a -> a
addHeader k v = updateHeaders $ H.insert k v


------------------------------------------------------------------------------
-- | Sets a header key-value-pair in a 'HasHeaders' datatype. If a header with
-- the same name already exists, it is overwritten with the new value.
setHeader :: (HasHeaders a) => CI ByteString -> ByteString -> a -> a
setHeader k v = updateHeaders $ H.set k v


------------------------------------------------------------------------------
-- | Gets a header value out of a 'HasHeaders' datatype.
getHeader :: (HasHeaders a) => CI ByteString -> a -> Maybe ByteString
getHeader k a = H.lookup k $ headers a


------------------------------------------------------------------------------
-- | Lists all the headers out of a 'HasHeaders' datatype. If many
-- headers came in with the same name, they will be catenated together.
listHeaders :: (HasHeaders a) => a -> [(CI ByteString, ByteString)]
listHeaders = H.toList . headers


------------------------------------------------------------------------------
-- | Clears a header value from a 'HasHeaders' datatype.
deleteHeader :: (HasHeaders a) => CI ByteString -> a -> a
deleteHeader k = updateHeaders $ H.delete k


------------------------------------------------------------------------------
-- | Enumerates the HTTP method values (see
-- <http://tools.ietf.org/html/rfc2068.html#section-5.1.1>).
data Method  = GET | HEAD | POST | PUT | DELETE | TRACE | OPTIONS | CONNECT |
               PATCH | Method ByteString
               deriving(Show, Read)

instance Eq Method where
    a == b =
        normalizeMethod a `eq` normalizeMethod b
      where
        GET       `eq` GET       = True
        HEAD      `eq` HEAD      = True
        POST      `eq` POST      = True
        PUT       `eq` PUT       = True
        DELETE    `eq` DELETE    = True
        TRACE     `eq` TRACE     = True
        OPTIONS   `eq` OPTIONS   = True
        CONNECT   `eq` CONNECT   = True
        PATCH     `eq` PATCH     = True
        Method x1 `eq` Method y1 = x1 == y1
        _         `eq` _         = False

instance Ord Method where
        compare a b =
            check (normalizeMethod a) (normalizeMethod b)
          where
            check   GET          GET           = EQ
            check   HEAD         HEAD          = EQ
            check   POST         POST          = EQ
            check   PUT          PUT           = EQ
            check   DELETE       DELETE        = EQ
            check   TRACE        TRACE         = EQ
            check   OPTIONS      OPTIONS       = EQ
            check   CONNECT      CONNECT       = EQ
            check   PATCH        PATCH         = EQ
            check   (Method  x1) (Method   y1) = compare x1 y1
            check   x            y             = compare (tag x) (tag y)

            tag :: Method -> Int
            tag (GET{})     = 0
            tag (HEAD{})    = 1
            tag (POST{})    = 2
            tag (PUT{})     = 3
            tag (DELETE{})  = 4
            tag (TRACE{})   = 5
            tag (OPTIONS{}) = 6
            tag (CONNECT{}) = 7
            tag (PATCH{})   = 8
            tag (Method{})  = 9

-- | Equate the special case constructors with their corresponding
-- @Method name@ variant.
{-# INLINE normalizeMethod #-}
normalizeMethod :: Method -> Method
normalizeMethod m@(Method name) = case name of
                                    "GET"     -> GET
                                    "HEAD"    -> HEAD
                                    "POST"    -> POST
                                    "PUT"     -> PUT
                                    "DELETE"  -> DELETE
                                    "TRACE"   -> TRACE
                                    "OPTIONS" -> OPTIONS
                                    "CONNECT" -> CONNECT
                                    "PATCH"   -> PATCH
                                    _         -> m
normalizeMethod m               = m


------------------------------------------------------------------------------
type HttpVersion = (Int,Int)


------------------------------------------------------------------------------
-- | A datatype representing an HTTP cookie.
data Cookie = Cookie {
      -- | The name of the cookie.
      cookieName     :: !ByteString

      -- | The cookie's string value.
    , cookieValue    :: !ByteString

      -- | The cookie's expiration value, if it has one.
    , cookieExpires  :: !(Maybe UTCTime)

      -- | The cookie's \"domain\" value, if it has one.
    , cookieDomain   :: !(Maybe ByteString)

      -- | The cookie path.
    , cookiePath     :: !(Maybe ByteString)

      -- | Tag as secure cookie?
    , cookieSecure   :: !Bool

      -- | HttpOnly?
    , cookieHttpOnly :: !Bool
} deriving (Eq, Show)


------------------------------------------------------------------------------
-- | A type alias for the HTTP parameters mapping. Each parameter
-- key maps to a list of ByteString values; if a parameter is specified
-- multiple times (e.g.: \"@GET /foo?param=bar1&param=bar2@\"), looking up
-- \"@param@\" in the mapping will give you @[\"bar1\", \"bar2\"]@.
type Params = Map ByteString [ByteString]


------------------------------------------------------------------------------
-- request type
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- | Contains all of the information about an incoming HTTP request.
data Request = Request
    { -- | The server name of the request, as it came in from the request's
      -- @Host:@ header.
      rqHostName      :: ByteString

      -- | The remote IP address.
    , rqClientAddr    :: ByteString

      -- | The remote TCP port number.
    , rqClientPort    :: {-# UNPACK #-} !Int

      -- | The local IP address for this request.
    , rqServerAddr    :: ByteString

      -- | Returns the port number the HTTP server is listening on. This may be
      -- useless from the perspective of external requests, e.g. if the server
      -- is running behind a proxy.
    , rqServerPort    :: {-# UNPACK #-} !Int

      -- | Returns the HTTP server's idea of its local hostname, including
      -- port. This is as configured with the @Config@ object at startup.
    , rqLocalHostname :: ByteString

      -- | Returns @True@ if this is an @HTTPS@ session.
    , rqIsSecure      :: !Bool
    , rqHeaders       :: Headers
    , rqBody          :: InputStream ByteString

      -- | Returns the @Content-Length@ of the HTTP request body.
    , rqContentLength :: !(Maybe Word64)

      -- | Returns the HTTP request method.
    , rqMethod        :: !Method

      -- | Returns the HTTP version used by the client.
    , rqVersion       :: {-# UNPACK #-} !HttpVersion

      -- | Returns a list of the cookies that came in from the HTTP request
      -- headers.
    , rqCookies       :: [Cookie]

      -- | Handlers can be hung on a @URI@ \"entry point\"; this is called the
      -- \"context path\". If a handler is hung on the context path
      -- @\"\/foo\/\"@, and you request @\"\/foo\/bar\"@, the value of
      -- 'rqPathInfo' will be @\"bar\"@.
      --
      -- The following identity holds:
      --
      -- > rqURI r == S.concat [ rqContextPath r
      -- >                     , rqPathInfo r
      -- >                     , let q = rqQueryString r
      -- >                       in if S.null q
      -- >                            then ""
      -- >                            else S.append "?" q
      -- >                     ]
    , rqPathInfo      :: ByteString

      -- | The \"context path\" of the request; catenating 'rqContextPath',
      -- and 'rqPathInfo' should get you back to the original 'rqURI'
      -- (ignoring query strings). The 'rqContextPath' always begins and ends
      -- with a slash (@\"\/\"@) character, and represents the path (relative
      -- to your component\/snaplet) you took to get to your handler.
    , rqContextPath   :: ByteString

      -- | Returns the @URI@ requested by the client.
    , rqURI           :: ByteString

      -- | Returns the HTTP query string for this 'Request'.
    , rqQueryString   :: ByteString

      -- | Returns the parameters mapping for this 'Request'. \"Parameters\"
      -- are automatically decoded from the URI's query string and @POST@ body
      -- and entered into this mapping. The 'rqParams' value is thus a union of
      -- 'rqQueryParams' and 'rqPostParams'.
    , rqParams        :: Params

      -- | The parameter mapping decoded from the URI's query string.
    , rqQueryParams   :: Params

      -- | The parameter mapping decoded from the POST body. Note that Snap
      -- only auto-decodes POST request bodies when the request's
      -- @Content-Type@ is @application/x-www-form-urlencoded@.
      -- For @multipart/form-data@ use 'Snap.Util.FileUploads.handleFileUploads'
      -- to decode the POST request and fill this mapping.
    , rqPostParams    :: Params
    }


------------------------------------------------------------------------------
instance Show Request where
  show r = concat [ "Request <\n"
                  , body
                  , ">" ]
    where
      body = concat $ map (("    "++) . (++ "\n")) [
                      sname
                    , remote
                    , local
                    , beginheaders
                    , hdrs
                    , endheaders
                    , contentlength
                    , method
                    , version
                    , cookies
                    , pathinfo
                    , contextpath
                    , uri
                    , params
                    ]

      sname         = concat [ "server-name: ", toStr $ rqLocalHostname r ]
      remote        = concat [ "remote: "
                             , toStr $ rqClientAddr r
                             , ":"
                             , show (rqClientPort r)
                             ]
      local         = concat [ "local: "
                             , toStr $ rqServerAddr r
                             , ":"
                             , show $ rqServerPort r
                             ]
      beginheaders  =
          "Headers:\n      ========================================"
      endheaders    = "  ========================================"
      hdrs' (a,b)   = (B.unpack $ CI.original a) ++ ": " ++ B.unpack b
      hdrs          = "      " ++ (concat $ intersperse "\n " $
                                   map hdrs' (H.toList $ rqHeaders r))
      contentlength = concat [ "content-length: "
                             , show $ rqContentLength r
                             ]
      method        = concat [ "method: "
                             , show $ rqMethod r
                             ]
      version       = concat [ "version: "
                             , show $ rqVersion r
                             ]
      cookies'      = "      " ++ (concat $ intersperse "\n " $
                                   map show $ rqCookies r)
      cookies       = concat
          [ "cookies:\n"
          , "      ========================================\n"
          , cookies'
          , "\n      ========================================"
          ]
      pathinfo      = concat [ "pathinfo: ", toStr $ rqPathInfo r ]
      contextpath   = concat [ "contextpath: ", toStr $ rqContextPath r ]
      uri           = concat [ "URI: ", toStr $ rqURI r ]
      params'       = "      " ++
                      (concat $ intersperse "\n " $
                       map (\ (a,b) -> B.unpack a ++ ": " ++ show b) $
                       Map.toAscList $ rqParams r)
      params        = concat
          [ "params:\n"
          , "      ========================================\n"
          , params'
          , "\n      ========================================"
          ]


------------------------------------------------------------------------------
instance HasHeaders Request where
    headers           = rqHeaders
    updateHeaders f r = r { rqHeaders = f (rqHeaders r) }


------------------------------------------------------------------------------
instance HasHeaders Headers where
    headers       = id
    updateHeaders = id

------------------------------------------------------------------------------
-- response type
------------------------------------------------------------------------------

type StreamProc = OutputStream Builder -> IO (OutputStream Builder)
data ResponseBody = Stream (StreamProc)
                      -- ^ output body is a function that writes to a 'Builder'
                      -- stream

                  | SendFile FilePath (Maybe (Word64, Word64))
                      -- ^ output body is sendfile(), optional second argument
                      --   is a byte range to send


------------------------------------------------------------------------------
rspBodyMap :: (StreamProc -> StreamProc) -> ResponseBody -> ResponseBody
rspBodyMap f b = Stream $ f $ rspBodyToEnum b


------------------------------------------------------------------------------
rspBodyToEnum :: ResponseBody -> StreamProc
rspBodyToEnum (Stream e) = e

rspBodyToEnum (SendFile fp Nothing) = \out ->
    Streams.withFileAsInput fp $ \is -> do
        is' <- Streams.mapM (return . fromByteString) is
        Streams.connect is' out
        return out

rspBodyToEnum (SendFile fp (Just (start, end))) = \out ->
    withBinaryFile fp ReadMode $ \handle -> do
        unless (start == 0) $ hSeek handle AbsoluteSeek $ toInteger start
        is  <- Streams.handleToInputStream handle
        is' <- Streams.takeBytes (fromIntegral $ end - start) is >>=
               Streams.mapM (return . fromByteString)
        Streams.connect is' out
        return out


------------------------------------------------------------------------------
-- | Represents an HTTP response.
data Response = Response
    { rspHeaders            :: Headers
    , rspCookies            :: Map ByteString Cookie

      -- | We will need to inspect the content length no matter what, and
      --   looking up \"content-length\" in the headers and parsing the number
      --   out of the text will be too expensive.
    , rspContentLength      :: !(Maybe Word64)
    , rspBody               :: ResponseBody

      -- | Returns the HTTP status code.
    , rspStatus             :: !Int

      -- | Returns the HTTP status explanation string.
    , rspStatusReason       :: !ByteString

      -- | If true, we are transforming the request body with
      -- 'transformRequestBody'
    , rspTransformingRqBody :: !Bool
    }


------------------------------------------------------------------------------
instance Show Response where
  show r = concat [ statusline
                  , hdrs
                  , "\r\n"
                  ]
    where
      statusline = concat [ "HTTP/1.1 "
                          , show $ rspStatus r
                          , " "
                          , toStr $ rspStatusReason r
                          , "\r\n" ]

      hdrs = concatMap showHdr $ H.toList $ rspHeaders r

      showHdr (k,v) = concat [ toStr (CI.original k), ": ", toStr v, "\r\n" ]


------------------------------------------------------------------------------
instance HasHeaders Response where
    headers = rspHeaders
    updateHeaders f r = r { rspHeaders = f (rspHeaders r) }


------------------------------------------------------------------------------
-- | Looks up the value(s) for the given named parameter. Parameters initially
-- come from the request's query string and any decoded POST body (if the
-- request's @Content-Type@ is @application\/x-www-form-urlencoded@).
-- Parameter values can be modified within handlers using "rqModifyParams".
rqParam :: ByteString           -- ^ parameter name to look up
        -> Request              -- ^ HTTP request
        -> Maybe [ByteString]
rqParam k rq = Map.lookup k $ rqParams rq
{-# INLINE rqParam #-}


------------------------------------------------------------------------------
-- | Looks up the value(s) for the given named parameter in the POST parameters
-- mapping.
rqPostParam :: ByteString           -- ^ parameter name to look up
            -> Request              -- ^ HTTP request
            -> Maybe [ByteString]
rqPostParam k rq = Map.lookup k $ rqPostParams rq
{-# INLINE rqPostParam #-}


------------------------------------------------------------------------------
-- | Looks up the value(s) for the given named parameter in the query
-- parameters mapping.
rqQueryParam :: ByteString           -- ^ parameter name to look up
             -> Request              -- ^ HTTP request
             -> Maybe [ByteString]
rqQueryParam k rq = Map.lookup k $ rqQueryParams rq
{-# INLINE rqQueryParam #-}


------------------------------------------------------------------------------
-- | Modifies the parameters mapping (which is a @Map ByteString ByteString@)
-- in a 'Request' using the given function.
rqModifyParams :: (Params -> Params) -> Request -> Request
rqModifyParams f r = r { rqParams = p }
  where
    p = f $ rqParams r
{-# INLINE rqModifyParams #-}


------------------------------------------------------------------------------
-- | Writes a key-value pair to the parameters mapping within the given
-- request.
rqSetParam :: ByteString        -- ^ parameter name
           -> [ByteString]      -- ^ parameter values
           -> Request           -- ^ request
           -> Request
rqSetParam k v = rqModifyParams $ Map.insert k v
{-# INLINE rqSetParam #-}


                                ---------------
                                -- responses --
                                ---------------

------------------------------------------------------------------------------
-- | An empty 'Response'.
emptyResponse :: Response
emptyResponse = Response H.empty Map.empty Nothing
                         (Stream (return . id))
                         200 "OK" False


------------------------------------------------------------------------------
-- | Sets an HTTP response body to the given stream procedure.
setResponseBody     :: (OutputStream Builder -> IO (OutputStream Builder))
                                   -- ^ new response body
                    -> Response    -- ^ response to modify
                    -> Response
setResponseBody e r = r { rspBody = Stream e }
{-# INLINE setResponseBody #-}


------------------------------------------------------------------------------
-- | Sets the HTTP response status. Note: normally you would use
-- 'setResponseCode' unless you needed a custom response explanation.
--
setResponseStatus   :: Int        -- ^ HTTP response integer code
                    -> ByteString -- ^ HTTP response explanation
                    -> Response   -- ^ Response to be modified
                    -> Response
setResponseStatus s reason r = r { rspStatus=s, rspStatusReason=reason }
{-# INLINE setResponseStatus #-}


------------------------------------------------------------------------------
-- | Sets the HTTP response code.
setResponseCode   :: Int        -- ^ HTTP response integer code
                  -> Response   -- ^ Response to be modified
                  -> Response
setResponseCode s r = setResponseStatus s reason r
  where
    reason = fromMaybe "Unknown" (IM.lookup s statusReasonMap)
{-# INLINE setResponseCode #-}


------------------------------------------------------------------------------
-- | Modifies a response body.
modifyResponseBody  :: ((OutputStream Builder -> IO (OutputStream Builder)) ->
                        (OutputStream Builder -> IO (OutputStream Builder)))
                    -> Response
                    -> Response
modifyResponseBody f r = r { rspBody = rspBodyMap f (rspBody r) }
{-# INLINE modifyResponseBody #-}


------------------------------------------------------------------------------
-- | Sets the @Content-Type@ in the 'Response' headers.
setContentType      :: ByteString -> Response -> Response
setContentType = setHeader "Content-Type"
{-# INLINE setContentType #-}


------------------------------------------------------------------------------
-- | Adds an HTTP 'Cookie' to 'Response' headers.
addResponseCookie :: Cookie            -- ^ cookie value
                  -> Response          -- ^ response to modify
                  -> Response
addResponseCookie ck@(Cookie k _ _ _ _ _ _) r = r { rspCookies = cks' }
  where
    cks'= Map.insert k ck $ rspCookies r
{-# INLINE addResponseCookie #-}


------------------------------------------------------------------------------
-- | Gets an HTTP 'Cookie' with the given name from 'Response' headers.
getResponseCookie :: ByteString            -- ^ cookie name
                  -> Response              -- ^ response to query
                  -> Maybe Cookie
getResponseCookie cn r = Map.lookup cn $ rspCookies r
{-# INLINE getResponseCookie #-}


-- | Returns a list of 'Cookie's present in 'Response'
getResponseCookies :: Response              -- ^ response to query
                   -> [Cookie]
getResponseCookies = Map.elems . rspCookies
{-# INLINE getResponseCookies #-}


------------------------------------------------------------------------------
-- | Deletes an HTTP 'Cookie' from the 'Response' headers. Please note
-- this does not necessarily erase the cookie from the client browser.
deleteResponseCookie :: ByteString        -- ^ cookie name
                     -> Response          -- ^ response to modify
                     -> Response
deleteResponseCookie cn r = r { rspCookies = cks' }
  where
    cks'= Map.delete cn $ rspCookies r
{-# INLINE deleteResponseCookie #-}


------------------------------------------------------------------------------
-- | Modifies an HTTP 'Cookie' with given name in 'Response' headers.
-- Nothing will happen if a matching 'Cookie' can not be found in 'Response'.
modifyResponseCookie :: ByteString          -- ^ cookie name
                     -> (Cookie -> Cookie)  -- ^ modifier function
                     -> Response            -- ^ response to modify
                     -> Response
modifyResponseCookie cn f r = maybe r modify $ getResponseCookie cn r
  where
    modify ck = addResponseCookie (f ck) r
{-# INLINE modifyResponseCookie #-}


------------------------------------------------------------------------------
-- | A note here: if you want to set the @Content-Length@ for the response,
-- Snap forces you to do it with this function rather than by setting it in
-- the headers; the @Content-Length@ in the headers will be ignored.
--
-- The reason for this is that Snap needs to look up the value of
-- @Content-Length@ for each request, and looking the string value up in the
-- headers and parsing the number out of the text will be too expensive.
--
-- If you don't set a content length in your response, HTTP keep-alive will be
-- disabled for HTTP\/1.0 clients, forcing a @Connection: close@. For
-- HTTP\/1.1 clients, Snap will switch to the chunked transfer encoding if
-- @Content-Length@ is not specified.
setContentLength    :: Word64 -> Response -> Response
setContentLength !l r = r { rspContentLength = Just l }
{-# INLINE setContentLength #-}


------------------------------------------------------------------------------
-- | Removes any @Content-Length@ set in the 'Response'.
clearContentLength :: Response -> Response
clearContentLength r = r { rspContentLength = Nothing }
{-# INLINE clearContentLength #-}


                               ----------------
                               -- HTTP dates --
                               ----------------

------------------------------------------------------------------------------
-- | Converts a 'CTime' into an HTTP timestamp.
formatHttpTime :: CTime -> IO ByteString


------------------------------------------------------------------------------
-- | Converts a 'CTime' into common log entry format.
formatLogTime :: CTime -> IO ByteString


------------------------------------------------------------------------------
-- | Converts an HTTP timestamp into a 'CTime'.
parseHttpTime :: ByteString -> IO CTime

#ifdef PORTABLE

------------------------------------------------------------------------------
-- local definitions
fromStr :: String -> ByteString
fromStr = B.pack
{-# INLINE fromStr #-}


------------------------------------------------------------------------------
formatHttpTime = return . format . toUTCTime
  where
    format :: UTCTime -> ByteString
    format = fromStr . formatTime defaultTimeLocale "%a, %d %b %Y %X GMT"

    toUTCTime :: CTime -> UTCTime
    toUTCTime = posixSecondsToUTCTime . realToFrac


------------------------------------------------------------------------------
formatLogTime ctime = do
  t <- utcToLocalZonedTime $ toUTCTime ctime
  return $! format t

  where
    format :: ZonedTime -> ByteString
    format = fromStr . formatTime defaultTimeLocale "%d/%b/%Y:%H:%M:%S %z"

    toUTCTime :: CTime -> UTCTime
    toUTCTime = posixSecondsToUTCTime . realToFrac


------------------------------------------------------------------------------
parseHttpTime = return . toCTime . prs . toStr
  where
    prs :: String -> Maybe UTCTime
    prs = parseTime defaultTimeLocale "%a, %d %b %Y %H:%M:%S GMT"

    toCTime :: Maybe UTCTime -> CTime
    toCTime (Just t) = fromInteger $ truncate $ utcTimeToPOSIXSeconds t
    toCTime Nothing  = fromInteger 0

#else

------------------------------------------------------------------------------
formatLogTime t = do
    ptr <- mallocBytes 40
    c_format_log_time t ptr
    S.unsafePackMallocCString ptr


------------------------------------------------------------------------------
formatHttpTime t = do
    ptr <- mallocBytes 40
    c_format_http_time t ptr
    S.unsafePackMallocCString ptr


------------------------------------------------------------------------------
parseHttpTime s = S.unsafeUseAsCString s $ \ptr ->
    c_parse_http_time ptr

#endif


------------------------------------------------------------------------------
-- private helper functions
toStr :: ByteString -> String
toStr = map w2c . S.unpack


------------------------------------------------------------------------------
statusReasonMap :: IM.IntMap ByteString
statusReasonMap = IM.fromList [
        (100, "Continue"),
        (101, "Switching Protocols"),
        (200, "OK"),
        (201, "Created"),
        (202, "Accepted"),
        (203, "Non-Authoritative Information"),
        (204, "No Content"),
        (205, "Reset Content"),
        (206, "Partial Content"),
        (300, "Multiple Choices"),
        (301, "Moved Permanently"),
        (302, "Found"),
        (303, "See Other"),
        (304, "Not Modified"),
        (305, "Use Proxy"),
        (307, "Temporary Redirect"),
        (400, "Bad Request"),
        (401, "Unauthorized"),
        (402, "Payment Required"),
        (403, "Forbidden"),
        (404, "Not Found"),
        (405, "Method Not Allowed"),
        (406, "Not Acceptable"),
        (407, "Proxy Authentication Required"),
        (408, "Request Time-out"),
        (409, "Conflict"),
        (410, "Gone"),
        (411, "Length Required"),
        (412, "Precondition Failed"),
        (413, "Request Entity Too Large"),
        (414, "Request-URI Too Large"),
        (415, "Unsupported Media Type"),
        (416, "Requested range not satisfiable"),
        (417, "Expectation Failed"),
        (500, "Internal Server Error"),
        (501, "Not Implemented"),
        (502, "Bad Gateway"),
        (503, "Service Unavailable"),
        (504, "Gateway Time-out"),
        (505, "HTTP Version not supported")
    ]
