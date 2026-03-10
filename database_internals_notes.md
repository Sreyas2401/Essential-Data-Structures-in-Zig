# B-Trees

## Trees for Disk-Based Storage 

- Balanced trees (like AVL Trees) give a time complexity of O(log N).
- Fanout: The maximum allowed number of children per node.
- Problems we face from using a BST on Disk: 
  
  1. Locality: Since elements are added in random order, there's no guarantee that a newly created node is written close to its parent, which means that node child pointers may span across several disk pages. We can improve the situation to an extent by using Paged Binary Trees. 
  2. Tree Height: Since binary trees have a fanout of 2, height is a binary logarithm of the number of the elements in the tree, and we have to perform O(log N) seeks to locate the searched element, and subsequently, perform the same number of disk transfers.

## Disk-Based Structures 

- On-disk structures are used when the amounts of data are so large that keeping an entire dataset is impossible or not feasible. 
- Only a fraction of the data can be cached in memory at any time, and the rest is stored on disk. 
- The tree suited for disk implementation has to exhibit the following properties: 
  
  1. High fanout to improve locality of the neighboring keys 
  2. Low height to reduce the number of seeks during traversal 

## Hard Disk Drives 

- 
