// Copyright (c) 2016 Matthew Yannascoli
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.


import UIKit
import CoreData


/// CoreDataStack (stack) is a basic setup that encapsulates the contexts and
/// `Persistent Store Coordinator` (coordinator) that are necessary for using Core Data.
/// Its written in Swift 2.2 and is supports iOS versions iOS8 and up.
///
///
/// The stack provides the following conveniences and features:
///     * Self contained into one file for easy copy-pasting.  Can be used as a jump-off point 
///       for more complicated stacks.
///     * Simple interface that bubbles up points of failure to the initializer.
///     * Concurrent writing to disk.
///     * Easy creation of a temporary concurrent context that propagates through the `mainContext`.
///     * Allows you to specify a container directory in order to "sandbox" the backing store files.
///     * Option to set up the coordinator with an in-memory option.
///     * Easy and safe cleanup of the store and deletion of the associated DB files.
///
///
/// Beyond these conveniences the intention in creating CoreDataStack is to create a simple
/// interface and implementation of a common stack setup. One of the core decisions
/// that guides its architecture is that the underlying `mainContext` and `writingContext` are
/// garuanteed to be valid instances (non-optional) for the life of the stack.  This has the
/// benefit of simplifying the API but also has the side effect of making the initialization
/// throwable.  This properly reflects the fact that setting up the store always has the
/// potential to fail when setting up the coodinator if, for example, the underlying DB files
/// have been corrupted.
///
/// Complicating matters is the fact that the underlying store can be deleted by the stack.  In
/// this case the `mainContext` and `writingContext` are both still valid instances but the
/// coordinator is nil. Calling `saveToDisk` at this point will return the
/// `CoreDataStackError.DeletedStore` error.  After calling `deleteStore` you should consider
/// the stack instance to be dead and release any references to it in your application.
///
/// The context configuration employed leverages Core Data's child/parent inheritance mechanisms.
/// In this stack the `mainContext` inherits from the `writingContext`.  The `writingContext`
/// is backed by the coordinator which actually writes to the database. You can spawn a concurrent
/// context that is a child of the `mainContext`.  Saves made on this context using the
/// `writeToDisk` method will propagate through the `mainContext` and eventually to disk. The
/// stack implementation employs a common setup:
///
///     [Persistent Store Coordinator] -> i/o to/from disk
///             ^
///             |
///     [Writing Context] -> Communicate with the coordinator off the main thread
///             ^
///             |
///       [Main Context] -> Child of the writing context, operates on the main thread
///             ^
///             |
///     [Concurrent Context] -> Spawned at will for work that shouldn't block the main thread.\
///
public class CoreDataStack {
    
    //MARK: Properties
    private let bundle: NSBundle
    private let modelName: String
    private let directoryURL: NSURL
    private let inMemoryStore: Bool
    
    private var persistentStoreCoordinator: NSPersistentStoreCoordinator?
    private var managedObjectModel: NSManagedObjectModel
    private let writingContext: NSManagedObjectContext
    
    private var deletedStore: Bool {
        guard persistentStoreCoordinator != nil else {
            return false
        }
        return true
    }
    
    private let storeType: String
    private let storeOptions: [String: Bool]
    
    ///Custom Errors
    public enum CoreDataStackError: ErrorType, CustomDebugStringConvertible {
        /// `DeletedStore` error will occur if `saveToDisk` or `concurrentStore` are called after
        /// the backing store for a stack has been deleted using the `deleteStore` method.
        case DeletedStore
        /// `InvalidModelPath` error will occur if no .momd file can be located at the
        /// culmulative `bundle` + `modelName` + `containerURL` path during initialization.
        case InvalidModelPath(path: NSURL?)
        
        public var debugDescription: String {
            switch self {
            case .DeletedStore:
                return "The backing store for this stack has been deleted."
            case .InvalidModelPath(let path):
                return "Unable to find model at path \(path)."
            }
        }
    }
    
    ///A NSManagedObjectContext that is created with the MainQueueConcurrencyType concurrencyType.
    ///`mainContext` is garuanteed to be a valid instance for the life of the stack.
    public let mainContext: NSManagedObjectContext
    
    
    /// Create a stack instance. Note, the underlying persistant store is set hardcoded to use an
    /// sqlite database and as basic migration options.
    ///
    /// - parameter bundle: Required. is a NSBundle in which your target NSManagedObjectModel
    ///                     can be found.
    ///
    /// - parameter directoryURL: Required. A URL that points to the directory in which the
    ///                           sqlite files will be stored.
    ///
    /// - parameter modelName: Required. A String that must correspond with the name of the
    ///                        backing `momd` file.
    ///
    /// - parameter inMemoryStore: Defaults to false. If true, will create the persistant store
    ///                            using the `NSInMemoryStoreType`.
    ///
    /// - parameter logOutput: Defaults to false. if true, will log helpful errors/debugging output.
    ///
    /// - throws: An error representing issues setting up the object model or coordinator.
    ///           Common problems are an invalid model path (combination of
    ///           bundle/directoryURL/modelName) or an corruption error to the underlying
    ///           .sqlite files.
    ///
    public required init(bundle: NSBundle, directoryURL: NSURL, modelName: String,
                         inMemoryStore: Bool = false, logOutput: Bool = false) throws {
        
        //Options
        self.bundle = bundle
        self.modelName = modelName
        self.directoryURL = directoryURL
        self.inMemoryStore = inMemoryStore
        
        
        //logging
        loggingOn = logOutput
        
        //store settings
        storeType = inMemoryStore ? NSInMemoryStoreType : NSSQLiteStoreType
        storeOptions = [
            NSMigratePersistentStoresAutomaticallyOption : true,
            NSInferMappingModelAutomaticallyOption : true
        ]
        
        // STACK SETUP
        //
        // Baking the full setup chain into the initializer to maintain `let` semantics for
        // the `mainContext. Not very pretty but it's better for the api interface because
        // using `var` + implicity unwrapped optional implies the instance could changed under
        // the hood.
        
        //Model
        let modelURL = bundle.URLForResource(modelName, withExtension: "momd")
        guard let mURL = modelURL else {
            Log("Unabled able to find object model file with name: \(modelName)")
            throw CoreDataStackError.InvalidModelPath(path: modelURL)
        }
        managedObjectModel = NSManagedObjectModel(contentsOfURL: mURL)!
        
        //Context Definition
        writingContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        mainContext = NSManagedObjectContext(concurrencyType: .MainQueueConcurrencyType)
        
        //Coordinator
        persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: managedObjectModel)
        let url = directoryURL.URLByAppendingPathComponent("\(modelName).sqlite")
        do {
            try persistentStoreCoordinator?.addPersistentStoreWithType(
                storeType, configuration: nil, URL: url, options: storeOptions)
        }
        catch let error as NSError {
            let message = "Attempt to add `persistentStoreCoordinator` failed with error: " +
                "\(error.localizedDescription). Removing store files..."
            
            Log(message)
            try removeDBFiles()
            throw error
        }
        
        //Context Association
        mainContext.parentContext = writingContext
        writingContext.persistentStoreCoordinator = persistentStoreCoordinator!
    }
}



//MARK: - API -
public extension CoreDataStack {
    
    /// Synchronously removes the backing sqlite files and resets the main and
    /// writing contexts. If the application is running in iOS 9 it leverages the new
    /// `destroyPersistentStoreAtURL` method that is provided by Core Data.  For iOS 8 devices
    /// this method will use `NSFileManager` to remove all the files that match the format
    /// modelName.sqlite* (includes -wal and -shm files).
    ///
    /// - throws: An NSError particular to either destroyPersistentStoreAtURL (iOS9) or
    ///           NSFileMananger.removeItemAtURL (iOS 8).
    public func deleteStore() throws {
        try removeDBFiles()
        
        //Clean out the contexts
        self.mainContext.reset()
        self.writingContext.reset()
    }
    
    /// Save down through the context chain to disk.
    ///
    /// - parameter context: an optional managed object context. If nothing is passed,
    ///                      mainContext is assumed.
    ///
    /// - parameter completion: an optional block that is called upon save completion.
    ///                         Dispatch occurs on the main queue.
    public func saveToDisk(context: NSManagedObjectContext? = nil, completion: ((error: ErrorType?) -> Void)? = nil) {
        guard deletedStore else {
            Log(CoreDataStackError.DeletedStore.debugDescription)
            completion?(error: CoreDataStackError.DeletedStore)
            return
        }
        
        func save(context: NSManagedObjectContext?, saveCompletion: (() -> Void)? = nil) {
            context?.performBlock {
                do {
                    try context?.save()
                    saveCompletion?()
                }
                catch let error as NSError {
                    Log("Context (\(context)) save failed with error: \(error.localizedDescription)")
                    self.onMain(withError: error, call: completion)
                }
            }
        }
        
        if let context = context where context != mainContext {
            //Propogate save down through the main context
            save(context) {
                save(self.mainContext) {
                    save(self.writingContext) {
                        self.onMain(call: completion)
                    }
                }
            }
        }
        else {
            save(self.mainContext) {
                save(self.writingContext) {
                    self.onMain(call: completion)
                }
            }
        }
    }
    
    /// Creates a managed object context that inherits from `mainContenxt`. Passing this
    /// context into the `saveToDisk` function will propagate the save through the `mainContext`
    /// on its way to the `writingContext`.
    ///
    /// - returns: A `NSManagedObjectContext`
    public func concurrentContext() -> NSManagedObjectContext {
        let managedObjectContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        managedObjectContext.parentContext = mainContext
        return managedObjectContext
    }
}




//MARK: - LifeCycle -
private extension CoreDataStack {
    
    private func removeDBFiles() throws {
        if #available(iOS 9.0, *) {
            try destroyPersistentStoreIOS9()
        }
        else {
            try destroyPersistentStoreIOS8()
        }
    }
    
    @available(iOS 9.0, *)
    private func destroyPersistentStoreIOS9() throws {
        //The store has already been destroyed if the persistentStoreCoordinator
        //is nil here so bail silently.
        guard let psc = persistentStoreCoordinator else {
            return
        }
        
        do {
            let url = directoryURL.URLByAppendingPathComponent("\(modelName).sqlite")
            try psc.destroyPersistentStoreAtURL(url, withType: storeType, options: storeOptions)
            
            //nil the coordinator instance because we determine if the stack is
            //"destroyed" by checking if the coordinator == nil or not.
            persistentStoreCoordinator = nil
        }
        catch let error as NSError {
            throw error
        }
    }
    
    private func destroyPersistentStoreIOS8() throws {
        //The store has already been destroyed if the persistentStoreCoordinator is nil
        //here so bail silently.
        guard let psc = persistentStoreCoordinator else {
            return
        }
        
        //Remove store(s)
        for store in psc.persistentStores {
            do {
                try self.persistentStoreCoordinator?.removePersistentStore(store)
                
                //nil the coordinator instance because we determine if the stack is "destroyed"
                //by checking if the coordinator == nil or not.
                persistentStoreCoordinator = nil
                
                //Remove all files that match modelName.sqlite* (includes -wal and -shm files)
                do {
                    let fileManager = NSFileManager.defaultManager()
                    let urls = try fileManager.contentsOfDirectoryAtURL(
                        self.directoryURL, includingPropertiesForKeys: [], options: .SkipsSubdirectoryDescendants)
                    
                    let sqliteUrls = urls.filter { nil != $0.absoluteString.rangeOfString("\(self.modelName).sqlite") }
                    for url in sqliteUrls {
                        do {
                            try fileManager.removeItemAtURL(url)
                        }
                        catch let error as NSError {
                            Log("Unable to remove sqlite file with error: \(error.localizedDescription)")
                            throw error
                        }
                    }
                }
                catch let error as NSError {
                    Log("Unable to fetch contents of container directory with error: \(error.localizedDescription)")
                    throw error
                }
                
            }
            catch let error as NSError {
                Log("Unable to remove the persistent store with error: \(error.localizedDescription)")
                throw error
            }
        }
    }
}



//MARK: - Utilities -
extension CoreDataStack {
    //Convenience for dispatching back on the main queue
    private func onMain(withError error: ErrorType? = nil, call completion: ((error: ErrorType?) -> Void)?) {
        dispatch_async(dispatch_get_main_queue()) {
            completion?(error: error)
        }
    }
}


//MARK: - Log -
private var loggingOn: Bool = false
private func Log(message: String, file: String = #file, function: String = #function, line: Int = #line) -> Void {
    guard loggingOn else {
        return
    }
    
    let string = String(
        "\n><><>< CoreDataStack ><><><\n" +
            "File: \(file)\n" +
            "Function: \(function), Line: \(line)\n" +
            message + "\n" +
        "><><><><><><><><><><><><><>\n"
    )
    
    print(string)
}
