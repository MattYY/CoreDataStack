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
/// [Private Writing Context (PWC)] -> concurrent, writes to disk
///             ^
///             |
///             |
///       [Main Context (MC)] -> synchronous, Child of PWC
///             ^
///             |
///             |
///     [Temporary Context] -> concurrent, spawn at will
///
/// ><><><><><><><

public class CoreDataStack {
    
    //MARK: Properties
    private let bundle: NSBundle
    private let modelName: String
    private let containerURL: NSURL
    private let inMemoryStore: Bool

    private var persistentStoreCoordinator: NSPersistentStoreCoordinator?
    private var managedObjectModel: NSManagedObjectModel?
    private var writingContext: NSManagedObjectContext?
    
    private var validContextState: Bool {
        guard let _ = mainContext, _ = writingContext else {
            return false
        }
        return true
    }
    
    
    ///Custom Errors
    public enum CoreDataStackError: ErrorType, CustomDebugStringConvertible {
        ///Occurs when `deleteStore` or `saveToDisk` is attempted but mainContext and/or writingContext are nil
        case InvalidContextState
        ///Occurs when `deleteStore` is attempted but `persistentStoreCoordinator` is nil
        case InvalidStore
        
        //case NotSetup
        
        public var debugDescription: String {
            switch self {
            case .InvalidContextState:
                let message = "This stack currently has a nil `mainContext` and/or a nil `writingContext`.  This is" +
                              "can happen if the `deleteStore` method is called without the rejuvenate flag set to" +
                              "true.  The only way to fix is to set up a new stack from scratch."
                return message
            case .InvalidStore:
                return "The persistent store is nil which can only be fixed by recreating the stack."
            }
        }
    }

    ///Reused completion block pattern that is used for completions.
    public typealias ErrorCompletionBlock = (error: ErrorType?) -> Void
    
    ///The main context. a NSManagedObjectContext that is created with the MainQueueConcurrencyType concurrencyType.
    private(set) internal var mainContext: NSManagedObjectContext?
    
    
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
        try setup()
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
            try removeDBFilesiOS9()
        } else {
            // Fallback on earlier versions
        }
        /*
        guard validContextState else {
            throw CoreDataStackError.InvalidContextState
        }
        
        do {
            try self.tearDown()
            do {
                //try self.removeDBFiles()
            }
            catch let error as NSError {
                throw error
            }
        }
        catch let error as NSError {
            throw error
        }
        */
    }
    
    
    ///Save down through the context chain to disk.
    /// - `context` : optional MOC.  If nothing is passed, mainContext is assumed.
    /// - `completion` : optional completion block. Called on the main queue.
    
    public func saveToDisk(context: NSManagedObjectContext? = nil, completion: ErrorCompletionBlock? = nil) {
        guard let mc = mainContext, wc = writingContext else {
            completion?(error: CoreDataStackError.InvalidContextState)
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
    
    
    /// Creates a concurrent context that inherits from the mainContext
    /// and will propogate its save down through the `mainContext` and ultimately to the
    /// `writingContext` when passed to the `saveToDisk` function.
    public func concurrentContext() -> NSManagedObjectContext? {
        guard let mc = self.mainContext else {
            Log("Unable to create concurrent context because the mainContext is not currently set up.")
            return nil
        }
        
        let managedObjectContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        managedObjectContext.parentContext = mc
        return managedObjectContext
    }
    
}


//MARK: - LifeCycle -
private extension CoreDataStack {
    
    private func setup() throws {
        
        //TODO: throw...
        
        //1.
        managedObjectModel = createManagedObjectModel()
        
        //2.
        persistentStoreCoordinator = createPersistentStoreCoordinator()
        
        //3.
        writingContext = createWritingContext()
        
        //4.
        mainContext = createMainContext()
    }
    
    
    private func tearDown() throws {
        if #available(iOS 9.0, *) {
            try removeDBFilesiOS9()
        } else {
            // Fallback on earlier versions
        }
        
//        managedObjectModel = nil
//        persistentStoreCoordinator = nil
//        self.mainContext?.reset()
//        self.mainContext = nil
//        self.writingContext?.reset()
//        self.writingContext = nil
    }
    
    
    private func removePersistentStore() throws {
        let lastStore = persistentStoreCoordinator?.persistentStores.last
        guard let store = lastStore else {
            throw CoreDataStackError.InvalidStore
        }
        
        do {
            try self.persistentStoreCoordinator?.removePersistentStore(store)
        }
        catch let error as NSError {
            Log("Unable to remove the persistent store with error: \(error.localizedDescription)")
            throw error
        }
    }
    
    private func removeDBFiles() throws {
//        if #available(iOS 9, *) {
//            try removeDBFilesiOS9()
//        } else {
//            try removeDBFilesiOS8()
//        }
    }
    
    @available(iOS 9.0, *)
    private func removeDBFilesiOS9() throws {
        let storeType = inMemoryStore ? NSInMemoryStoreType : NSSQLiteStoreType
        let options = [
            NSMigratePersistentStoresAutomaticallyOption : true,
            NSInferMappingModelAutomaticallyOption : true
        ]
        
        do {
            let url = containerURL.URLByAppendingPathComponent("\(modelName).sqlite")
            try persistentStoreCoordinator?.destroyPersistentStoreAtURL(url, withType: storeType, options: options)
        }
        catch let error as NSError {
            throw error
        }
    }
    
    
    private func removeDBFilesiOS8() throws {
        let fileManager = NSFileManager.defaultManager()
        do {
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
}



//MARK: - Stack -
extension CoreDataStack {
    
    private func createManagedObjectModel() -> NSManagedObjectModel? {
        guard managedObjectModel == nil else {
            return managedObjectModel!
        }
        
        let modelURL = bundle.URLForResource(modelName, withExtension: "momd")
        guard let mURL = modelURL else {
            Log("Unabled able to find object model file with name: \(modelName)")
            return nil
        }
        
        guard let managedObjectModel = NSManagedObjectModel(contentsOfURL: mURL) else {
            Log("Unabled to instantiate `managedObjectModel` with name \"\(modelName)\".  Bailing.")
            return nil
        }
        
        return managedObjectModel
    }
    
    
    private func createPersistentStoreCoordinator() -> NSPersistentStoreCoordinator? {
        guard let mom = managedObjectModel else {
            Log("Attempting to create a `persistentStoreCoordinator` but one already exists.")
            return nil
        }
        
        guard persistentStoreCoordinator == nil else {
            return persistentStoreCoordinator
        }
        
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: mom)
        let url = containerURL.URLByAppendingPathComponent("\(modelName).sqlite")
        let storeType = inMemoryStore ? NSInMemoryStoreType : NSSQLiteStoreType
        
        let options = [
            NSMigratePersistentStoresAutomaticallyOption : true,
            NSInferMappingModelAutomaticallyOption : true
        ]
        
        do {
            try coordinator.addPersistentStoreWithType(storeType, configuration: nil, URL: url, options: options)
        }
        catch let error as NSError {
            Log("Attempt to add `persistentStoreCoordinator` failed with error: \(error.localizedDescription)")
            do {
                try self.removeDBFiles()
            }
            catch {}
        }
        
        return coordinator
    }
    
    
    private func createWritingContext() -> NSManagedObjectContext? {
        guard let psc = persistentStoreCoordinator else {
            Log("Attempting to create `writingContext` before the `persistentStoreCoordinator` is set up.")
            return nil
        }
        
        guard writingContext == nil else {
            return writingContext
        }

        let managedObjectContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        managedObjectContext.persistentStoreCoordinator = psc
        return managedObjectContext
    }
    
    
    private func createMainContext() -> NSManagedObjectContext? {
        guard let wc = writingContext else {
            Log("Attempting to create `mainContext` before the persistent store coordinator is setup.")
            return nil
        }
        
        guard mainContext == nil else {
            return mainContext
        }

        let managedObjectContext = NSManagedObjectContext(concurrencyType: .MainQueueConcurrencyType)
        managedObjectContext.parentContext = wc
        return managedObjectContext
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
    
    print(">< CoreDataStack ><")
    print("File: \(file)")
    print("Function: \(function), Line: \(line)")
    debugPrint(message)
    print("><><><><><><><><><><")
}





