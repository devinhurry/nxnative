using System;
using System.Collections.Generic;

namespace Ryujinx.Graphics.Shader.IntermediateRepresentation
{
    class PhiNode : INode
    {
        private Operand _dest;

        public Operand Dest
        {
            get => _dest;
            set => _dest = AssignDest(value);
        }

        public int DestsCount => _dest != null ? 1 : 0;

        public BasicBlock Block { get; }

        private readonly HashSet<BasicBlock> _blocks;

        private class PhiSource
        {
            public BasicBlock Block { get; }
            public Operand Operand { get; set; }
            public List<BasicBlock> Incoming { get; } = [];

            public PhiSource(BasicBlock block, Operand operand)
            {
                Block = block;
                Operand = operand;
            }
        }

        private readonly List<PhiSource> _sources;

        public int SourcesCount => _sources.Count;

        public PhiNode(Operand dest, BasicBlock block = null)
        {
            Block = block;
            _blocks = [];

            _sources = [];

            dest.AsgOp = this;

            Dest = dest;
        }

        private Operand AssignDest(Operand dest)
        {
            if (dest != null && dest.Type == OperandType.LocalVariable)
            {
                dest.AsgOp = this;
            }

            return dest;
        }

        public void AddSource(BasicBlock block, Operand operand, BasicBlock predecessor = null)
        {
            if (_blocks.Add(block))
            {
                if (operand.Type == OperandType.LocalVariable)
                {
                    operand.UseOps.Add(this);
                }

                _sources.Add(new PhiSource(block, operand));
            }
            // Definition blocks can precede the join by several edges. Keep the
            // actual incoming edges as well, without changing existing users.
            if (predecessor != null)
            {
                foreach (PhiSource source in _sources)
                {
                    if (source.Block == block && !source.Incoming.Contains(predecessor)) source.Incoming.Add(predecessor);
                }
            }
        }

        public IReadOnlyList<BasicBlock> GetSourcePredecessors(int index) => _sources[index].Incoming;

        public Operand GetDest(int index)
        {
            ArgumentOutOfRangeException.ThrowIfNotEqual(index, 0);

            return _dest;
        }

        public Operand GetSource(int index)
        {
            return _sources[index].Operand;
        }

        public BasicBlock GetBlock(int index)
        {
            return _sources[index].Block;
        }

        public void SetSource(int index, Operand source)
        {
            Operand oldSrc = _sources[index].Operand;

            if (oldSrc != null && oldSrc.Type == OperandType.LocalVariable)
            {
                oldSrc.UseOps.Remove(this);
            }

            if (source.Type == OperandType.LocalVariable)
            {
                source.UseOps.Add(this);
            }

            _sources[index].Operand = source;
        }
    }
}
