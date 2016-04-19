#CoreDataStack

A simple Core Data stack written in Swift. Supports **iOS 8 and up**.

##Features
 * Concurrent writing to disk  
 * Ability to create a temporary concurrent context that propogates through the `mainContext`  
 * Ability to "sandbox" the backing store files in a custom directory.  
 * Ability to set up the coordinator with an in-memory option.  
 * Easy and safe clean up of the store and deletion of the associated DB files


CoreDataStack is a basic setup that encapsulates the contexts and "Persistent Store Coordinator" (coordinator) that are necessary for using Core Data.
Its written in **Swift 2.2** and is supports iOS versions **iOS8 and up**.


The stack provides the following conveniences and features:  
    * Concurrent writing to disk  
    * Ability to create a temporary concurrent context that propogates through the `mainContext`  
    * Ability to "sandbox" the backing store files in a custom directory.  
    * Ability to set up the coordinator with an in-memory option.  
    * Easy and safe clean up of the store and deletion of the associated DB files  


Beyond these conveniences the intention in creating CoreDataStack is to create a simple
interface and implementation of a common stack setup. One of the core decisions
that guides its architecture is that the underlying `mainContext` and `writingContext` are garuanteed to be valid instances (non-optional) for the life of the stack.  This has the benefit of simplifying the API but also has the side effect of making the initialization throwable.  This properly reflects the fact that setting up the store always has the potential to fail when setting up the coodinator if, for example, the underlying DB files have been corrupted.

Complicating matters is the fact that the underlying store can be deleted by the stack.  In this case the `mainContext` and `writingContext` are both still valid instances but the coordinator is nil. Calling `saveToDisk` or spawning a `concurrentContext` at this point will return the `CoreDataStackError.DeletedStore` error.  After calling `deleteStore` you should consider the stack to be dead and release any references to it in your application.

The context configuration employed leverages Core Data's child/parent inheritance mechanisms. In this stack the `mainContext` inherits from the `writingContext`.  The `writingContext` is backed by the coordinator which actually writes to the database. You can spawn a concurrent context that is a child of the `mainContext`.  Saves made on this context using the  `writeToDisk` method will propagate through the `mainContext` and eventually to disk.


    [Writing Context] -> concurrent, writes to disk
            ↑
      [Main Context] -> synchronous, Child of WC
            ↑
    [Concurrent Context] -> Temporary context which can be spawned at will.

