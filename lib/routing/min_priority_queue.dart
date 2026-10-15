class QueueEntry {
  final String nodeId;
  final double priority;
  const QueueEntry(this.nodeId, this.priority);
}

/// A small binary min-heap. Lowest priority comes out first.
class MinPriorityQueue {
  final List<QueueEntry> _heap = [];

  bool get isEmpty => _heap.isEmpty;

  void add(String nodeId, double priority) {
    _heap.add(QueueEntry(nodeId, priority));
    _siftUp(_heap.length - 1);
  }

  QueueEntry removeFirst() {
    final first = _heap.first;
    final last = _heap.removeLast();
    if (_heap.isNotEmpty) {
      _heap[0] = last;
      _siftDown(0);
    }
    return first;
  }

  void _siftUp(int index) {
    while (index > 0) {
      final parent = (index - 1) ~/ 2;
      if (_heap[index].priority >= _heap[parent].priority) break;
      _swap(index, parent);
      index = parent;
    }
  }

  void _siftDown(int index) {
    final length = _heap.length;
    while (true) {
      final left = 2 * index + 1;
      final right = left + 1;
      var smallest = index;
      if (left < length && _heap[left].priority < _heap[smallest].priority) {
        smallest = left;
      }
      if (right < length && _heap[right].priority < _heap[smallest].priority) {
        smallest = right;
      }
      if (smallest == index) break;
      _swap(index, smallest);
      index = smallest;
    }
  }

  void _swap(int a, int b) {
    final temp = _heap[a];
    _heap[a] = _heap[b];
    _heap[b] = temp;
  }
}
