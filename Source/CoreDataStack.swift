//
//  CoreDataStack.swift
//  CoreDataStack
//
//  Created by Matthew Yannascoli on 4/1/16.
//  Copyright © 2016 Matthew Yannascoli. All rights reserved.
//


import UIKit
import CoreData


/// CoreDataStack (stack) is a basic setup that encapsulates the contexts and
/// `Persistent Store Coordinator` (coordinator) that are necessary for using Core Data.
/// Its written in Swift 2.2 and is supports iOS versions iOS8 and up.
///
///
/// The stack provides the following conveniences and features:
///     * Concurrent writing to disk
///     * Ability to create a temporary concurrent context that propogates
///       through the `mainContext`
///     * Ability to "sandbox" the backing store files in a custom directory.
///     * Ability to set up the coordinator with an in-memory option.
///     * Easy clean up of the store and deletion of the associated DB files
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
/// coordinator is nil. Calling `saveToDisk` or spawning a `concurrentContext` at this point
/// will return the `CoreDataStackError.DeletedStore` error.  After calling `deleteStore` you
/// should consider the stack to be dead and release any references to it in your application.
///
/// The context configuration employed leverages Core Data's child/parent inheritance mechanisms.
/// In this stack the `mainContext` inherits from the `writingContext`.  The `writingContext`
/// is backed by the coordinator which actually writes to the database. You can spawn a concurrent
/// context that is a child of the `mainContext`.  Saves made on this context using the 
/// `writeToDisk` method will propagate through the `mainContext` and eventually to disk.
///
///
///     [Writing Context] -> concurrent, writes to disk
///             ^
///             |
///             |
///       [Main Context] -> synchronous, Child of WC
///             ^
///             |
///             |
///     [Concurrent Context] -> Temporary context which can be spawned at will.
///
///
public class CoreDataStack {
    
    //MARK: Properties
    private let bundle: NSBundle
    private let modelName: String
    private let containerURL: NSURL
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
    
    
    /// Create a stack instance.
    ///
    /// - Requires: `bundle` is a NSBundle in which your target NSManagedObjectModel can be found.
    ///
    /// - Requires: `modelName` is a String that must correspond with the name of the 
    ///   backing `momd` file/
    ///
    /// - Requires: `containerURL` is a URL that points to the directory in which the
    ///   sqlite files will be stored.
    ///
    /// - `inMemoryStore` Defaults to false. if true, will create the persistant store
    ///   using the `NSInMemoryStoreType`
    ///
    /// - `logOutput`:defaults to false. if true, will log helpful errors/debugging output.
    ///
    /// The underlying persistant store is set hardcoded to use an sqlite database and as basic
    /// migration options (`NSMigratePersistentStoresAutomaticallyOption` and
    ///  `NSInferMappingModelAutomaticallyOption`) set to true.
    
    public required init(bundle: NSBundle, modelName: String, containerURL: NSURL,
                         inMemoryStore: Bool = false, logOutput: Bool = false) throws {
        
        //Options
        self.bundle = bundle
        self.modelName = modelName
        self.containerURL = containerURL
        self.inMemoryStore = inMemoryStore
        
        
        //logging
        loggingOn = logOutput
        
        //store settings
        storeType = inMemoryStore ? NSInMemoryStoreType : NSSQLiteStoreType
        storeOptions = [
            NSMigratePersistentStoresAutomaticallyOption : true,
            NSInferMappingModelAutomaticallyOption : true
        ]
        
        //
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
        let url = containerURL.URLByAppendingPathComponent("\(modelName).sqlite")
        do {
            try persistentStoreCoordinator?.addPersistentStoreWithType(storeType, configuration: nil, URL: url, options: storeOptions)
        }
        catch let error as NSError {
            let message = "Attempt to add `persistentStoreCoordinator` failed with error: " +
                "\(error.localizedDescription). Removing store files..."
            
            Log(message)
            try removeDBFiles()
        }
        
        //Context Association
        mainContext.parentContext = writingContext
        writingContext.persistentStoreCoordinator = persistentStoreCoordinator!
    }
}



//MARK: - API -
public extension CoreDataStack {

    /// `deleteStore` synchronously removes the backing sqlite files and resets the main and
    /// writing contexts. If the application is running in iOS 9 it leverages the new
    /// `destroyPersistentStoreAtURL` method that is provided by Core Data.  For iOS 8 devices
    /// this method will use `NSFileManager` to do the deletion and will delete all the 
    /// .sqlite files that match the format modelName.sqlite* (includes -wal and -shm files).
    public func deleteStore() throws {
        try removeDBFiles()
        
        //Clean out the contexts
        self.mainContext.reset()
        self.writingContext.reset()
    }
    
    ///Save down through the context chain to disk.
    /// - `context` : optional MOC.  If nothing is passed, mainContext is assumed.
    /// - `completion` : optional completion block. Called on the main queue.
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
    
    /// `concurrentContext` returns a context that is initialized with the
    /// `PrivateQueueConcurrencyType` and inherits from the `mainContext`. Passing this
    /// context into the `saveToDisk` function will propagate the save through the `mainContext`
    /// and then `writingContext` on it's way to disk.
    public func concurrentContext() -> NSManagedObjectContext? {
        guard deletedStore else {
            Log(CoreDataStackError.DeletedStore.debugDescription)
            return nil
        }
        
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
        } else {
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
            let url = containerURL.URLByAppendingPathComponent("\(modelName).sqlite")
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
                        self.containerURL, includingPropertiesForKeys: [], options: .SkipsSubdirectoryDescendants)
                    
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
    private func onMain(withError error: ErrorType? = nil, call completion: ((error: ErrorType?) -> Void)?)  {
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
