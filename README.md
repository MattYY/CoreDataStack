#CoreDataStack

A simple Core Data stack written in Swift 2.2. Supports **iOS 8 and up**.

##Features
 * Simple interface that bubbles up points of failure to the initializer
 * Concurrent writing to disk  
 * Easy creation of a temporary concurrent context that propogates through the `mainContext`  
 * Ability to initialize the store with a container directory URL in order to "sandbox" the backing store files.  
 * Option to set up the coordinator with an in-memory option.  
 * Easy and safe clean up of the store and deletion of the associated DB files
