#CoreDataStack

A super simple (one page, under 400 lines) Core Data stack written in Swift. Tested in **iOS 8 and up**.

##Features
 * Self contained into one file for easy copy-pasting.  Can be used as a jump-off point for more complicated stacks.
 * Simple interface that bubbles up points of failure to the initializer.
 * Concurrent writing to disk.
 * Easy creation of a temporary concurrent context that propagates through the `mainContext`.
 * Allows you to specify a container directory in order to "sandbox" the backing store files.  
 * Option to set up the coordinator with an in-memory option.  
 * Easy and safe cleanup of the store and deletion of the associated DB files.
 


##Usage

To use copy the `CoreDataStack.swift` file into your project and create a stack instance:

```swift
//Initialization
let bundle = NSBundle.mainBundle()
let directoryURL = "...DocumentDirectory..."
let modelName = "DataModel" //don't include extension
	
let stack = try! CoreDataStack(bundle: bundle, directoryURL: directoryURL, modelName: modelName)
```

If you balk at the forced try used here read below for why I argue that it's ok.  Once you have a stack its `mainContext` is guaranteed to be a non-optional instance and you can safely use it to create, fetch and save:

```swift
//Create
let description = NSEntityDescription.entityForName("TestEntity", inManagedObjectContext: stack.mainContext)
guard let description = description else {
	return	  				
}
NSManagedObject(entity: description, insertIntoManagedObjectContext: stack.mainContext)

//Fetch
stack.mainContext.performBlock {	
	let fetchRequest = NSFetchRequest(entityName: "TestEntity")
    do {
        let results = try stack.mainContext.executeFetchRequest(fetchRequest)
    }
    catch let error as NSError {
    	//handle error
    }
}

//Save	
stack.saveToDisk() {
	error in 
	//save complete
}
```

For larger work loads you probably want to use a concurrent context.  Use `concurrentContext()` to create one and then pass this to `saveToDisk` to save its contents down through the context hierarchy:

```swift
let concurrentContext = stack.concurrentContext()
stack.saveToDisk(concurrentContext) {
    error in
    //save complete
}
```

If you'd like to permanently remove the underlying database files for a stack call the `deleteStore` method:

```swift
do {
	try deleteStore()
}
catch let error as NSError {
	//handle error
}
```

After calling `deleteStore` the underlying persistent store coordinator will be nil and subsequent calls to `saveToDisk` or `deleteStore` will return a `CoreDataStackError.DeletedStore` error.

For additional usage info, checkout the **CoreDataStack.swift** method/property documentation. 



##Contexts

The underlying stack setup uses a common paradigm:

	[Persistent Store Coordinator] -> i/o to disk
			↑
	[Writing Context] -> concurrent context 
			↑
	[Main Context] -> child of the writing context
			↑
	[Temp Concurrent Context] -> Concurrent context, spawn at will!
	    
	    
This setup offers a robust concurrency implementation while being simple and maintainable.  In it, objects are created or fetched on a temporary concurrent context ("Temp Concurrent Context").  When this context is saved its data is propagated down through the main context ("Main Context") which will cause any listening NSFetchedResultControllers to update automatically. Following the main context save data propagation will progress to the "Writing Context" which communicates directly with the Persistent Store Coordinator.  Using a concurrent context at this stage ensures any disk operations do not block the UI.  

Many more details about this setup can be found across the web-o-sphere including some talk about how it performs slower than some other setups.  In my opinion the simplicity and flexibility of this solution is worth the minor speed reduction for the majority of project needs.


##Api 
One of my main goals in writing this class was to make the API as user friendly as possible.  To me this meant:  

1. Eliminating the optionality of the stack's contexts to avoid having to always unwrap them.   
2. Having clear and isolated points of failure.
 
To achieve these aims `CoreDataStack.swift` bubbles up its main points of failure to the initializer. There are two main ways the stack initialization could fail, an invalid path to a model file or a corrupted database file. The former of these is a user error and should be easily fixable. The latter should be a very rare circumstance and likely means the database needs to be deleted and made afresh. Indeed `CoreDataStack.swift` will remove the underlying database files if a corruption error occurs so that the app can recover and does not get stuck in an infinite failure loop. 

At this point, if your app requires a functioning database to work correctly (which is most often the case) it's ok for the app to crash.  And, if crashing is ok why not try! your way out of unwrapping-optional hell?  Free your mind of best practices and force-try-bang your way to freedom! You can always handle a stack setup error but then you'll have to either unwrap your contexts or force bang anyways:

```swift

//optional stack, safe but annoying.
var stack: CoreDataStack?
do {
	stack = try CoreDataStack(bundle: bundle, directoryURL: directoryURL, modelName: modelName)
}
catch let e as CoreDataStackError {
	//handle error
}

//ugh unwrapping...
guard let s = stack else {
	return
}
...

NSManagedObject(entity: description, insertIntoManagedObjectContext: s.mainContext)

...
```

One more note.  As mentioned, calling `deleteStore` on a stack will nil its Persistent Store Coordinator.  This will not nil `mainContext` and `writingContext` but they will be reset which releases their contents from memory.
