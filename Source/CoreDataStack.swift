//
//  CoreDataStack.swift
//  CoreDataStack
//
//  Created by Matthew Yannascoli on 4/1/16.
//  Copyright © 2016 my. All rights reserved.
//


import UIKit
import CoreData


/// ><><><><><><><
///
/// CoreDataStack is a basic coredata setup that enables the creation of contained (sandboxed) instances
/// of a store and provides commonly used conveniences like deleting the store and creating an inMemory instance
/// for testing.
///
/// The underlying coredata configuration is typical where the `mainContext` inherits from
/// a concurrent private writing context that references the persistent store coordinator and
/// does the actual writing to disk.
///
///     [Writing Context] -> concurrent, writes to disk
///             ^
///             |
///             |
///       [Main Context] -> synchronous, Child of WC
///             ^
///             |
///             |
///     [Concurrent Context] -> Temporary context which can be spawned at will.  Use for large fetches.
///
/// ><><><><><><><

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
        guard persistentStoreCoordinator == nil else {
            return false
        }
        return true
    }
    
    private let storeType: String
    private let storeOptions: [String: Bool]
    
    
    ///Custom Errors
    public enum CoreDataStackError: ErrorType, CustomDebugStringConvertible {
        case DeletedStore
        case InvalidModelPath(path: NSURL?)
        
        public var debugDescription: String {
            switch self {
            case .DeletedStore:
                return "The backing store for this stack has been deleted. " +
                       "Saves are no longer possible with this stack instance."
            
            case .InvalidModelPath(let path):
                return "Unable to find model at path \(path)."
            }
        }
    }

    ///Reused completion block pattern that is used for completions.
    public typealias ErrorCompletionBlock = (error: ErrorType?) -> Void
    
    ///The main context. a NSManagedObjectContext that is created with the MainQueueConcurrencyType concurrencyType.
    public let mainContext: NSManagedObjectContext
    
    
    /// Create a stack instance.
    /// - `bundle` (required): NSBundle in which your target NSManagedObjectModel can be found.
    /// - `modelName` (required): must correspond with the name of the backing NSManagedObjectModel
    /// - `containerURL` (required): is a URL that points to the folder in which the backing sqlite files will be stored.
    /// - `inMemoryStore` :defaults to false. if true, will create the persistant store using the `NSInMemoryStoreType`
    /// - `logDebugOutput`:defaults to false. if true, will log helpful errors/debugging output.
    ///
    /// The underlying persistant store is set hardcoded to use an sqlite database and as basic migration options
    /// (`NSMigratePersistentStoresAutomaticallyOption` and `NSInferMappingModelAutomaticallyOption`) set to true.
    
    public required init(bundle: NSBundle, modelName: String, containerURL: NSURL, inMemoryStore: Bool = false, logOutput: Bool = false) throws {
        self.bundle = bundle
        self.modelName = modelName
        self.containerURL = containerURL
        self.inMemoryStore = inMemoryStore
        
        loggingOn = logOutput
        
        
        storeType = inMemoryStore ? NSInMemoryStoreType : NSSQLiteStoreType
        storeOptions = [
            NSMigratePersistentStoresAutomaticallyOption : true,
            NSInferMappingModelAutomaticallyOption : true
        ]
        
        //managedObjectModel
        let modelURL = bundle.URLForResource(modelName, withExtension: "momd")
        guard let mURL = modelURL else {
            Log("Unabled able to find object model file with name: \(modelName)")
            throw CoreDataStackError.InvalidModelPath(path: modelURL)
        }
  
        managedObjectModel = NSManagedObjectModel(contentsOfURL: mURL)!
        
        //writingContext
        guard let psc = persistentStoreCoordinator else {
            fatalError("Attempting to create `writingContext` before the `persistentStoreCoordinator` is set up.")
        }
        
        writingContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        writingContext.persistentStoreCoordinator = psc
        
        //mainContext
        mainContext = NSManagedObjectContext(concurrencyType: .MainQueueConcurrencyType)
        mainContext.parentContext = writingContext
        
        //persistentStoreCoordinator
        persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: managedObjectModel)
        let url = containerURL.URLByAppendingPathComponent("\(modelName).sqlite")
        
        do {
            try persistentStoreCoordinator?.addPersistentStoreWithType(storeType, configuration: nil, URL: url, options: storeOptions)
        }
        catch let error as NSError {
            let message = "Attempt to add `persistentStoreCoordinator` failed with error: " +
                "\(error.localizedDescription). Deleting store..."
            
            Log(message)
            try deleteStore()
        }
    }
}



//MARK: - API -
/// ><><><><><><><
public extension CoreDataStack {

    
    
    ///Tears down the stack by removing and niling the current persistentStoreCoordinator, niling the
    ///managedObjectModel and resets the writing and main contexts in a thread-safe manner. Subsequently,
    ///all the files with an sqlite* extension (the sqlite, sqlite-wal and sqlite-shm) are deleted from disk.
    ///This deletion is done asyncronously on the `writingContext` but is ultimately dispatched back to main.
    ///
    ///¡BE CAREFUL! as your DB data will not be recoverable after this method is called.
    ///
    ///By default the `rejuvenate` option is set to true which will cause the stack to be setup again from scratch.
    ///If you do not wish the stack to be rejuvenated in this manner pass false.  Effectively, this will render
    ///the stack instance useless but is valuable if you are planning on discontinuing the stack altogether
    ///and do not wish to incur the extra overhead of setting it up again.
    ///
    ///The optional completion block param is called on the main queue.
    
    public func deleteStore() throws {
        if #available(iOS 9.0, *) {
            try destroyPersistentStoreIOS9()
        } else {
            try destroyPersistentStoreIOS8()
        }
        
        //Clear out any unsaved context objects
        self.mainContext.reset()
        self.writingContext.reset()
    }
    
    
    ///Save down through the context chain to disk.
    /// - `context` : optional MOC.  If nothing is passed, mainContext is assumed.
    /// - `completion` : optional completion block. Called on the main queue.
    
    public func saveToDisk(context: NSManagedObjectContext? = nil, completion: ErrorCompletionBlock? = nil) {
        guard deletedStore else {
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
    
    
    /// Creates a concurrent context that inherits from the mainContext and will propogate its save down
    /// through the `mainContext` and ultimately to the `writingContext` when passed to the `saveToDisk` function.
    public func concurrentContext() -> NSManagedObjectContext? {
        guard deletedStore else {
            return nil
        }
        
        let managedObjectContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        managedObjectContext.parentContext = mainContext
        return managedObjectContext
    }
    
}




//MARK: - LifeCycle -
private extension CoreDataStack {


    @available(iOS 9.0, *)
    private func destroyPersistentStoreIOS9() throws {
        //The store has already been destroyed if the persistentStoreCoordinator is nil here so bail silently.
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
        //The store has already been destroyed if the persistentStoreCoordinator is nil here so bail silently.
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
    private func onMain(withError error: ErrorType? = nil, call completion: ErrorCompletionBlock?)  {
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
        "><><>< CoreDataStack ><><><\n" +
        "File: \(file)\n" +
        "Function: \(function), Line: \(line)\n" +
        message +
        "><><><><><><><><><><><><><>"
    )
    
    print(string)
}





