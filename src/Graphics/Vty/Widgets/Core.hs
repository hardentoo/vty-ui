{-# LANGUAGE CPP, ExistentialQuantification #-}
-- |This module provides a basic infrastructure for modelling a user
-- interface widget and converting it to Vty's 'Image' type.
module Graphics.Vty.Widgets.Core
    ( WidgetImpl(..)
    , Widget
    , renderAndPosition
    , render
    , updateWidget
    , updateWidget_
    , updateWidgetState
    , updateWidgetState_
    , newWidget
    , getState
    , getPhysicalSize
    , setPhysicalPosition
    , getPhysicalPosition
    , (<~)
    , (<~~)

    -- ** Miscellaneous
    , Orientation(..)
    , withWidth
    , withHeight

    , growVertical
    , growHorizontal

    -- ** Events
    , handleKeyEvent
    , onKeyPressed
    , onGainFocus
    , onLoseFocus

    -- ** Focus management
    , FocusGroup
    , newFocusGroup
    , addToFocusGroup
    , addToFocusGroup_
    , focusNext
    , focusPrevious
    , setCurrentFocus
    , getCursorPosition
    , setFocusGroup
    , getFocusGroup
    , focus
    , unfocus
    )
where

import GHC.Word ( Word )
import Data.IORef
    ( IORef
    , newIORef
    , readIORef
    , modifyIORef
    , writeIORef
    )
import Control.Applicative
    ( (<$>)
    )
import Control.Monad
    ( when
    )
import Control.Monad.Reader
    ( ReaderT
    , runReaderT
    , ask
    )
import Control.Monad.Trans
    ( MonadIO
    , liftIO
    )
import Graphics.Vty
    ( DisplayRegion(DisplayRegion)
    , Image
    , Attr
    , Key(..)
    , Modifier
    , image_width
    , image_height
    , empty_image
    )

-- |A simple orientation type.
data Orientation = Horizontal | Vertical
                   deriving (Eq, Show)

-- |The type of user interface widgets.  A 'Widget' provides several
-- properties:
--
-- * /Growth properties/ which provide information about how to
--   allocate space to widgets depending on their propensity to
--   consume available space
--
-- * A /rendering routine/ which converts the widget's internal state
--   into a 'Render' value.
--
-- Of primary concern is the rendering routine, 'render'.  The
-- rendering routine takes one parameter: the size of the space in
-- which the widget should be rendered.  The space is important
-- because it provides a maximum size for the widget.  For widgets
-- that consume all available space, the size of the resulting
-- 'Render' will be equal to the supplied size.  For smaller widgets
-- (e.g., a simple string of text), the size of the 'Render' will
-- likely be much smaller than the supplied size.  In any case, any
-- 'Widget' implementation /must/ obey the rule that the resulting
-- 'Render' must not exceed the supplied 'DisplayRegion' in size.  If
-- it does, there's a good chance your interface will be garbled.
--
-- If the widget has child widgets, the supplied size should be
-- subdivided to fit the child widgets as appropriate.  How the space
-- is subdivided may depend on the growth properties of the children
-- or it may be a matter of policy.
data WidgetImpl a = WidgetImpl {
    -- |User-defined state type.
      state :: a

    -- |Render the widget with the given dimensions.  The result
    -- /must/ not be larger than the specified dimensions, but may be
    -- smaller.
    , draw :: Widget a -> DisplayRegion -> Maybe Attr -> IO Image

    -- |Will this widget expand to take advantage of available
    -- horizontal space?
    , getGrowHorizontal :: ReaderT a IO Bool

    -- |Will this widget expand to take advantage of available
    -- vertical space?
    , getGrowVertical :: ReaderT a IO Bool

    , physicalSize :: DisplayRegion
    , physicalPosition :: DisplayRegion

    , setPosition :: Widget a -> DisplayRegion -> IO ()

    , keyEventHandler :: Widget a -> Key -> [Modifier] -> IO Bool

    , gainFocus :: Widget a -> IO ()
    , loseFocus :: Widget a -> IO ()
    , focused :: Bool
    , focusGroup :: Widget a -> IO (Maybe (Widget FocusGroup))

    , cursorInfo :: Widget a -> IO (Maybe DisplayRegion)
    }

type Widget a = IORef (WidgetImpl a)

setFocusGroup :: (MonadIO m) => Widget a -> Widget FocusGroup -> m ()
setFocusGroup wRef fg =
    updateWidget_ wRef $ \w -> w { focusGroup = const $ return $ Just fg }

getFocusGroup :: (MonadIO m) => Widget a -> m (Maybe (Widget FocusGroup))
getFocusGroup wRef = do
  act <- focusGroup <~ wRef
  liftIO $ act wRef

growHorizontal :: (MonadIO m) => Widget a -> m Bool
growHorizontal w = do
  act <- getGrowHorizontal <~ w
  st <- state <~ w
  liftIO $ runReaderT act st

growVertical :: (MonadIO m) => Widget a -> m Bool
growVertical w = do
  act <- getGrowVertical <~ w
  st <- state <~ w
  liftIO $ runReaderT act st

render :: (MonadIO m) => Widget a -> DisplayRegion -> Maybe Attr -> m Image
render wRef sz overrideAttr =
    liftIO $ do
      impl <- readIORef wRef
      img <- draw impl wRef sz overrideAttr
      setPhysicalSize wRef $ DisplayRegion (image_width img) (image_height img)
      return img

renderAndPosition :: (MonadIO m) => Widget a -> DisplayRegion -> DisplayRegion
                  -> Maybe Attr -> m Image
renderAndPosition wRef pos sz mAttr = do
  img <- render wRef sz mAttr
  -- Position post-processing depends on the sizes being correct!
  setPhysicalPosition wRef pos
  return img

setPhysicalSize :: (MonadIO m) => Widget a -> DisplayRegion -> m ()
setPhysicalSize wRef newSize =
    liftIO $ modifyIORef wRef $ \w -> w { physicalSize = newSize }

getPhysicalSize :: (MonadIO m) => Widget a -> m DisplayRegion
getPhysicalSize wRef = (return . physicalSize) =<< (liftIO $ readIORef wRef)

getPhysicalPosition :: (MonadIO m, Functor m) => Widget a -> m DisplayRegion
getPhysicalPosition wRef = physicalPosition <$> (liftIO $ readIORef wRef)

setPhysicalPosition :: (MonadIO m) => Widget a -> DisplayRegion -> m ()
setPhysicalPosition wRef pos =
    liftIO $ do
      w <- readIORef wRef
      (setPosition w) wRef pos

newWidget :: (MonadIO m) => m (Widget a)
newWidget =
    liftIO $ newIORef $ WidgetImpl { state = undefined
                                   , draw = undefined
                                   , getGrowVertical = undefined
                                   , getGrowHorizontal = undefined
                                   , keyEventHandler = \_ _ _ -> return False
                                   , physicalSize = DisplayRegion 0 0
                                   , physicalPosition = DisplayRegion 0 0
                                   , gainFocus =
                                       \this -> updateWidget_ this $ \w -> w { focused = True }
                                   , loseFocus =
                                       \this -> updateWidget_ this $ \w -> w { focused = False }
                                   , focused = False
                                   , cursorInfo = const $ return Nothing
                                   , setPosition =
                                       \this newPos ->
                                           updateWidget_ this $ \w -> w { physicalPosition = newPos }
                                   , focusGroup = const $ return Nothing
                                   }

handleKeyEvent :: (MonadIO m) => Widget a -> Key -> [Modifier] -> m Bool
handleKeyEvent wRef keyEvent mods = do
  act <- keyEventHandler <~ wRef
  liftIO $ act wRef keyEvent mods

onKeyPressed :: (MonadIO m) => Widget a -> (Widget a -> Key -> [Modifier] -> IO Bool) -> m ()
onKeyPressed wRef handler = do
  -- Create a new handler that calls this one but defers to the old
  -- one if the new one doesn't handle the event.
  oldHandler <- keyEventHandler <~ wRef

  let combinedHandler =
          \w k ms -> do
            v <- handler w k ms
            case v of
              True -> return True
              False -> oldHandler w k ms

  updateWidget_ wRef $ \w -> w { keyEventHandler = combinedHandler }

focus :: (MonadIO m) => Widget a -> m ()
focus wRef = do
  act <- gainFocus <~ wRef
  liftIO $ act wRef

unfocus :: (MonadIO m) => Widget a -> m ()
unfocus wRef = do
  act <- loseFocus <~ wRef
  liftIO $ act wRef

onGainFocus :: (MonadIO m) => Widget a -> (Widget a -> IO ()) -> m ()
onGainFocus wRef handler = do
  oldHandler <- gainFocus <~ wRef
  let combinedHandler = \w -> oldHandler w >> handler w
  updateWidget_ wRef $ \w -> w { gainFocus = combinedHandler }

onLoseFocus :: (MonadIO m) => Widget a -> (Widget a -> IO ()) -> m ()
onLoseFocus wRef handler = do
  oldHandler <- loseFocus <~ wRef
  let combinedHandler = \w -> oldHandler w >> handler w
  updateWidget_ wRef $ \w -> w { loseFocus = combinedHandler }

(<~) :: (MonadIO m) => (WidgetImpl a -> b) -> Widget a -> m b
(<~) f wRef = (return . f) =<< (liftIO $ readIORef wRef)

(<~~) :: (MonadIO m) => (a -> b) -> Widget a -> m b
(<~~) f wRef = (return . f . state) =<< (liftIO $ readIORef wRef)

updateWidget :: (MonadIO m) => Widget a -> (WidgetImpl a -> WidgetImpl a) -> m (Widget a)
updateWidget wRef f = (liftIO $ modifyIORef wRef f) >> return wRef

updateWidget_ :: (MonadIO m) => Widget a -> (WidgetImpl a -> WidgetImpl a) -> m ()
updateWidget_ wRef f = updateWidget wRef f >> return ()

getState :: (MonadIO m) => Widget a -> m a
getState wRef = state <~ wRef

updateWidgetState :: (MonadIO m) => Widget a -> (a -> a) -> m (Widget a)
updateWidgetState wRef f =
    liftIO $ do
      w <- readIORef wRef
      writeIORef wRef $ w { state = f (state w) }
      return wRef

updateWidgetState_ :: (MonadIO m) => Widget a -> (a -> a) -> m ()
updateWidgetState_ wRef f = updateWidgetState wRef f >> return ()

-- |Modify the width component of a 'DisplayRegion'.
withWidth :: DisplayRegion -> Word -> DisplayRegion
withWidth (DisplayRegion _ h) w = DisplayRegion w h

-- |Modify the height component of a 'DisplayRegion'.
withHeight :: DisplayRegion -> Word -> DisplayRegion
withHeight (DisplayRegion w _) h = DisplayRegion w h

data FocusEntry = forall a. FocusEntry (Widget a)

data FocusGroup = FocusGroup { entries :: [Widget FocusEntry]
                             , currentEntryNum :: Int
                             }

newFocusEntry :: (MonadIO m) =>
                 Widget a
              -> m (Widget FocusEntry)
newFocusEntry chRef = do
  wRef <- newWidget
  updateWidget_ wRef $ \w ->
      w { state = FocusEntry chRef

        , getGrowHorizontal = do
            (FocusEntry ch) <- ask
            growHorizontal ch

        , getGrowVertical = do
            (FocusEntry ch) <- ask
            growVertical ch

        , draw =
            \this sz mAttr -> do
              (FocusEntry ch) <- getState this
              render ch sz mAttr

        , setPosition =
            \this pos -> do
              (setPosition w) this pos
              (FocusEntry ch) <- getState this
              setPhysicalPosition ch pos
        }

  wRef `onLoseFocus` (const $ unfocus chRef)
  wRef `onGainFocus` (const $ focus chRef)
  wRef `onKeyPressed` (\_ k -> handleKeyEvent chRef k)

  return wRef

newFocusGroup :: (MonadIO m) => Widget a -> m (Widget FocusGroup, Widget FocusEntry)
newFocusGroup initialWidget = do
  wRef <- newWidget
  eRef <- newFocusEntry initialWidget
  focus eRef

  updateWidget_ wRef $ \w ->
      w { state = FocusGroup { entries = [eRef]
                             , currentEntryNum = 0
                             }
        , getGrowHorizontal = return False
        , getGrowVertical = return False
        , keyEventHandler =
            \this key mods -> do
              st <- getState this
              case currentEntryNum st of
                (-1) -> return False
                i -> do
                  case key of
                    (KASCII '\t') -> do
                             focusNext this
                             return True
                    k -> do
                       let e = entries st !! i
                       handleKeyEvent e k mods

        -- Should never be rendered.
        , draw = \_ _ _ -> return empty_image
        }

  return (wRef, eRef)

getCursorPosition :: (MonadIO m) => Widget FocusGroup -> m (Maybe DisplayRegion)
getCursorPosition wRef = do
  eRef <- currentEntry wRef
  (FocusEntry w) <- state <~ eRef
  ci <- cursorInfo <~ w
  liftIO (ci w)

currentEntry :: (MonadIO m) => Widget FocusGroup -> m (Widget FocusEntry)
currentEntry wRef = do
  es <- entries <~~ wRef
  i <- currentEntryNum <~~ wRef
  return (es !! i)

addToFocusGroup :: (MonadIO m) => Widget FocusGroup -> Widget a -> m (Widget FocusEntry)
addToFocusGroup cRef wRef = do
  eRef <- newFocusEntry wRef
  updateWidgetState_ cRef $ \s -> s { entries = (entries s) ++ [eRef] }
  return eRef

addToFocusGroup_ :: (MonadIO m) => Widget FocusGroup -> Widget a -> m ()
addToFocusGroup_ cRef wRef = addToFocusGroup cRef wRef >> return ()

focusNext :: (MonadIO m) => Widget FocusGroup -> m ()
focusNext wRef = do
  st <- getState wRef
  let cur = currentEntryNum st
  if cur < length (entries st) - 1 then
      setCurrentFocus wRef (cur + 1) else
      setCurrentFocus wRef 0

focusPrevious :: (MonadIO m) => Widget FocusGroup -> m ()
focusPrevious wRef = do
  st <- getState wRef
  let cur = currentEntryNum st
  if cur > 0 then
      setCurrentFocus wRef (cur - 1) else
      setCurrentFocus wRef (length (entries st) - 1)

setCurrentFocus :: (MonadIO m) => Widget FocusGroup -> Int -> m ()
setCurrentFocus cRef i = do
  st <- state <~ cRef

  when (i >= length (entries st) || i < 0) $
       error $ "collection index " ++ (show i) ++
                 " bad; size is " ++ (show $ length $ entries st)

  -- If new entry number is different from existing one, invoke focus
  -- handlers.
  when (currentEntryNum st /= i) $
       do
         unfocus ((entries st) !! (currentEntryNum st))
         focus ((entries st) !! i)

  updateWidgetState_ cRef $ \s -> s { currentEntryNum = i }